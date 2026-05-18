// SPDX-License-Identifier: GPL-2.0-only
/*
 * actiondfs - read-only action input manifest filesystem for actiond.
 *
 * Mount data:
 *   root=<input-root-directory-digest-hash>,cas=/cas/blobs/sha256
 *
 * Directory/FileNode metadata is read lazily from REAPI Directory protos stored
 * in the CAS. File contents are read by digest from the same CAS blob root.
 */

#include <linux/cred.h>
#include <linux/delay.h>
#include <linux/err.h>
#include <linux/fs.h>
#include <linux/hashtable.h>
#include <linux/highmem.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/magic.h>
#include <linux/module.h>
#include <linux/mount.h>
#include <linux/mutex.h>
#include <linux/namei.h>
#include <linux/pagemap.h>
#include <linux/parser.h>
#include <linux/path.h>
#include <linux/slab.h>
#include <linux/statfs.h>
#include <linux/string.h>
#include <linux/uaccess.h>
#include <linux/vmalloc.h>

#define ACTIONDFS_MAGIC 0x41444653
#define ACTIONDFS_MAX_DIRECTORY_PROTO_SIZE (64U * 1024U * 1024U)
#define ACTIONDFS_DIR_MODE 0777
#define ACTIONDFS_STALE_RETRY_ATTEMPTS 128
#define ACTIONDFS_STALE_RETRY_MS 2
#define ACTIONDFS_DIR_CACHE_BITS 12

enum actiondfs_lookup_mode {
	ACTIONDFS_LOOKUP_CANONICAL,
	ACTIONDFS_LOOKUP_HYBRID32,
};

struct actiondfs_cached_child {
	char *name;
	size_t name_len;
	umode_t mode;
	u64 size;
	char hash[65];
};

struct actiondfs_cached_dir {
	struct hlist_node hnode;
	char hash[65];
	struct actiondfs_cached_child *file_children;
	size_t file_count;
	size_t file_capacity;
	struct actiondfs_cached_child *dir_children;
	size_t dir_count;
	size_t dir_capacity;
};

struct actiondfs_node {
	char *name;
	size_t name_len;
	bool name_borrowed;
	u64 ino;
	umode_t mode;
	u64 size;
	char hash[65];
	struct file *blob_file;
	struct mutex blob_lock;
	bool loaded;
	struct actiondfs_node *parent;
	struct actiondfs_cached_dir *cached_dir;
	struct actiondfs_node **file_children;
	size_t file_count;
	size_t file_capacity;
	struct actiondfs_node **dir_children;
	size_t dir_count;
	size_t dir_capacity;
};

struct actiondfs_sb_info {
	char *cas_root;
	char *root_hash;
	struct path cas_path;
	bool cas_path_valid;
	struct actiondfs_node *root;
	u64 next_ino;
	enum actiondfs_lookup_mode lookup_mode;
	bool use_dir_cache;
	struct mutex load_lock;
};

/*
 * Directory protos are content-addressed and immutable. Keep a VM-lifetime
 * parsed metadata cache for non-root directories so repeated tree artifacts
 * don't re-read and re-parse the same CAS blob for every action mount.
 */
static DEFINE_HASHTABLE(actiondfs_dir_cache, ACTIONDFS_DIR_CACHE_BITS);
static DEFINE_MUTEX(actiondfs_dir_cache_lock);

static const struct inode_operations actiondfs_dir_iops;
static const struct inode_operations actiondfs_file_iops;
static const struct file_operations actiondfs_dir_fops;
static const struct file_operations actiondfs_file_fops;
static const struct address_space_operations actiondfs_aops;

static struct actiondfs_sb_info *actiondfs_sbi(struct super_block *sb)
{
	return sb->s_fs_info;
}

static bool actiondfs_is_dir(const struct actiondfs_node *node)
{
	return S_ISDIR(node->mode);
}

static void actiondfs_free_tree(struct actiondfs_node *node)
{
	size_t i;

	if (!node)
		return;

	for (i = 0; i < node->file_count; i++)
		actiondfs_free_tree(node->file_children[i]);
	for (i = 0; i < node->dir_count; i++)
		actiondfs_free_tree(node->dir_children[i]);

	if (node->blob_file)
		filp_close(node->blob_file, NULL);
	kfree(node->file_children);
	kfree(node->dir_children);
	if (!node->name_borrowed)
		kfree(node->name);
	kfree(node);
}

static void actiondfs_clear_children(struct actiondfs_node *node)
{
	size_t i;

	for (i = 0; i < node->file_count; i++)
		actiondfs_free_tree(node->file_children[i]);
	for (i = 0; i < node->dir_count; i++)
		actiondfs_free_tree(node->dir_children[i]);
	kfree(node->file_children);
	kfree(node->dir_children);
	node->file_children = NULL;
	node->file_count = 0;
	node->file_capacity = 0;
	node->dir_children = NULL;
	node->dir_count = 0;
	node->dir_capacity = 0;
	node->cached_dir = NULL;
}

static struct actiondfs_node *actiondfs_alloc_node_len(struct actiondfs_sb_info *sbi,
						       const char *name,
						       size_t name_len,
						       umode_t mode)
{
	struct actiondfs_node *node;

	node = kzalloc(sizeof(*node), GFP_KERNEL);
	if (!node)
		return NULL;

	node->name = kmemdup_nul(name, name_len, GFP_KERNEL);
	if (!node->name) {
		kfree(node);
		return NULL;
	}

	node->name_len = name_len;
	node->ino = ++sbi->next_ino;
	node->mode = mode;
	node->loaded = true;
	mutex_init(&node->blob_lock);
	return node;
}

static struct actiondfs_node *
actiondfs_alloc_node_borrowed_name(struct actiondfs_sb_info *sbi,
				   const char *name,
				   size_t name_len,
				   umode_t mode)
{
	struct actiondfs_node *node;

	node = kzalloc(sizeof(*node), GFP_KERNEL);
	if (!node)
		return NULL;

	node->name = (char *)name;
	node->name_len = name_len;
	node->name_borrowed = true;
	node->ino = ++sbi->next_ino;
	node->mode = mode;
	node->loaded = true;
	mutex_init(&node->blob_lock);
	return node;
}

static struct actiondfs_node *actiondfs_alloc_node(struct actiondfs_sb_info *sbi,
						   const char *name,
						   umode_t mode)
{
	return actiondfs_alloc_node_len(sbi, name, strlen(name), mode);
}

static int actiondfs_compare_name(const char *lhs, size_t lhs_len,
				  const char *rhs, size_t rhs_len)
{
	size_t common = min(lhs_len, rhs_len);
	int cmp;

	cmp = memcmp(lhs, rhs, common);
	if (cmp < 0)
		return -1;
	if (cmp > 0)
		return 1;
	if (lhs_len < rhs_len)
		return -1;
	if (lhs_len > rhs_len)
		return 1;
	return 0;
}

static struct actiondfs_node *actiondfs_find_child_linear_range(struct actiondfs_node **children,
								size_t lo,
								size_t hi,
								const char *name,
								size_t len)
{
	size_t i;

	for (i = lo; i < hi; i++) {
		struct actiondfs_node *child = children[i];

		if (child->name_len == len && !memcmp(child->name, name, len))
			return child;
	}
	return NULL;
}

static struct actiondfs_node *actiondfs_find_child_hybrid_in(struct actiondfs_node **children,
							     size_t count,
							     const char *name,
							     size_t len,
							     size_t linear_threshold)
{
	size_t lo = 0;
	size_t hi = count;

	while (hi - lo > linear_threshold) {
		size_t mid = lo + (hi - lo) / 2;
		struct actiondfs_node *child = children[mid];
		int cmp = actiondfs_compare_name(child->name, child->name_len,
						 name, len);

		if (cmp < 0) {
			lo = mid + 1;
		} else if (cmp > 0) {
			hi = mid;
		} else {
			return child;
		}
	}

	return actiondfs_find_child_linear_range(children, lo, hi, name, len);
}

static struct actiondfs_node *actiondfs_find_child_hybrid(struct actiondfs_node *dir,
							  const char *name,
							  size_t len,
							  size_t linear_threshold)
{
	struct actiondfs_node *child;

	child = actiondfs_find_child_hybrid_in(dir->file_children, dir->file_count,
					       name, len, linear_threshold);
	if (child)
		return child;
	return actiondfs_find_child_hybrid_in(dir->dir_children, dir->dir_count,
					      name, len, linear_threshold);
}

static size_t actiondfs_linear_threshold(enum actiondfs_lookup_mode lookup_mode)
{
	switch (lookup_mode) {
	case ACTIONDFS_LOOKUP_HYBRID32:
		return 32;
	case ACTIONDFS_LOOKUP_CANONICAL:
	default:
		return 0;
	}
}

static struct actiondfs_node *actiondfs_find_child(struct actiondfs_sb_info *sbi,
						   struct actiondfs_node *dir,
						   const char *name,
						   size_t len)
{
	return actiondfs_find_child_hybrid(dir, name, len,
					   actiondfs_linear_threshold(sbi->lookup_mode));
}

static bool actiondfs_find_cached_child_linear_range(struct actiondfs_cached_child *children,
						     size_t lo,
						     size_t hi,
						     const char *name,
						     size_t len,
						     size_t *out)
{
	size_t i;

	for (i = lo; i < hi; i++) {
		struct actiondfs_cached_child *child = &children[i];

		if (child->name_len == len && !memcmp(child->name, name, len)) {
			*out = i;
			return true;
		}
	}
	return false;
}

static bool actiondfs_find_cached_child_hybrid_in(struct actiondfs_cached_child *children,
						  size_t count,
						  const char *name,
						  size_t len,
						  size_t linear_threshold,
						  size_t *out)
{
	size_t lo = 0;
	size_t hi = count;

	while (hi - lo > linear_threshold) {
		size_t mid = lo + (hi - lo) / 2;
		struct actiondfs_cached_child *child = &children[mid];
		int cmp = actiondfs_compare_name(child->name, child->name_len,
						 name, len);

		if (cmp < 0) {
			lo = mid + 1;
		} else if (cmp > 0) {
			hi = mid;
		} else {
			*out = mid;
			return true;
		}
	}

	return actiondfs_find_cached_child_linear_range(children, lo, hi,
							name, len, out);
}

static struct actiondfs_node *
actiondfs_materialize_cached_child(struct actiondfs_sb_info *sbi,
				   struct actiondfs_node *parent,
				   struct actiondfs_cached_child *record,
				   struct actiondfs_node **slot)
{
	struct actiondfs_node *existing;
	struct actiondfs_node *node;

	existing = smp_load_acquire(slot);
	if (existing)
		return existing;

	node = actiondfs_alloc_node_borrowed_name(sbi, record->name,
						  record->name_len,
						  record->mode);
	if (!node)
		return ERR_PTR(-ENOMEM);

	node->parent = parent;
	node->size = record->size;
	memcpy(node->hash, record->hash, 64);
	node->hash[64] = '\0';
	if (S_ISDIR(record->mode))
		node->loaded = false;

	smp_store_release(slot, node);
	return node;
}

static struct actiondfs_node *
actiondfs_lookup_cached_child_locked(struct actiondfs_sb_info *sbi,
				     struct actiondfs_node *dir,
				     const char *name,
				     size_t len)
{
	struct actiondfs_cached_dir *cached = dir->cached_dir;
	size_t index;

	if (actiondfs_find_cached_child_hybrid_in(cached->file_children,
						  cached->file_count,
						  name, len,
						  actiondfs_linear_threshold(sbi->lookup_mode),
						  &index))
		return actiondfs_materialize_cached_child(sbi, dir,
							  &cached->file_children[index],
							  &dir->file_children[index]);

	if (actiondfs_find_cached_child_hybrid_in(cached->dir_children,
						  cached->dir_count,
						  name, len,
						  actiondfs_linear_threshold(sbi->lookup_mode),
						  &index))
		return actiondfs_materialize_cached_child(sbi, dir,
							  &cached->dir_children[index],
							  &dir->dir_children[index]);

	return NULL;
}

static struct actiondfs_node *actiondfs_lookup_child(struct actiondfs_sb_info *sbi,
						     struct actiondfs_node *dir,
						     const char *name,
						     size_t len)
{
	struct actiondfs_node *child;

	if (!dir->cached_dir)
		return actiondfs_find_child(sbi, dir, name, len);

	mutex_lock(&sbi->load_lock);
	child = actiondfs_lookup_cached_child_locked(sbi, dir, name, len);
	mutex_unlock(&sbi->load_lock);
	return child;
}

static int actiondfs_validate_no_cross_type_duplicates(struct actiondfs_node *dir)
{
	size_t file_index = 0;
	size_t dir_index = 0;

	while (file_index < dir->file_count && dir_index < dir->dir_count) {
		struct actiondfs_node *file = dir->file_children[file_index];
		struct actiondfs_node *child_dir = dir->dir_children[dir_index];
		int cmp = actiondfs_compare_name(file->name, file->name_len,
						 child_dir->name,
						 child_dir->name_len);

		if (!cmp)
			return -EEXIST;
		if (cmp < 0)
			file_index++;
		else
			dir_index++;
	}
	return 0;
}

static int actiondfs_validate_next_cached_child(struct actiondfs_cached_child *children,
						size_t count,
						const char *name,
						size_t name_len)
{
	struct actiondfs_cached_child *last;

	if (!count)
		return 0;

	last = &children[count - 1];
	if (actiondfs_compare_name(last->name, last->name_len, name, name_len) >= 0)
		return -EINVAL;
	return 0;
}

static int
actiondfs_validate_no_cross_type_cached_duplicates(struct actiondfs_cached_dir *dir)
{
	size_t file_index = 0;
	size_t dir_index = 0;

	while (file_index < dir->file_count && dir_index < dir->dir_count) {
		struct actiondfs_cached_child *file = &dir->file_children[file_index];
		struct actiondfs_cached_child *child_dir = &dir->dir_children[dir_index];
		int cmp = actiondfs_compare_name(file->name, file->name_len,
						 child_dir->name,
						 child_dir->name_len);

		if (!cmp)
			return -EEXIST;
		if (cmp < 0)
			file_index++;
		else
			dir_index++;
	}
	return 0;
}

static int actiondfs_valid_component(const char *name, size_t len)
{
	if (!len || len > NAME_MAX)
		return -EINVAL;
	if ((len == 1 && name[0] == '.') ||
	    (len == 2 && name[0] == '.' && name[1] == '.'))
		return -EINVAL;
	if (memchr(name, '\0', len))
		return -EINVAL;
	return 0;
}

static void actiondfs_free_cached_dir(struct actiondfs_cached_dir *dir)
{
	size_t i;

	if (!dir)
		return;
	for (i = 0; i < dir->file_count; i++)
		kfree(dir->file_children[i].name);
	for (i = 0; i < dir->dir_count; i++)
		kfree(dir->dir_children[i].name);
	kfree(dir->file_children);
	kfree(dir->dir_children);
	kfree(dir);
}

static void actiondfs_destroy_dir_cache(void)
{
	struct actiondfs_cached_dir *entry;
	struct hlist_node *tmp;
	unsigned int bucket;

	mutex_lock(&actiondfs_dir_cache_lock);
	hash_for_each_safe(actiondfs_dir_cache, bucket, tmp, entry, hnode) {
		hash_del(&entry->hnode);
		actiondfs_free_cached_dir(entry);
	}
	mutex_unlock(&actiondfs_dir_cache_lock);
}

static int actiondfs_validate_next_child(struct actiondfs_node **children,
					 size_t count,
					 const char *name,
					 size_t name_len)
{
	struct actiondfs_node *last;

	if (!count)
		return 0;

	last = children[count - 1];
	if (actiondfs_compare_name(last->name, last->name_len, name, name_len) >= 0)
		return -EINVAL;
	return 0;
}

static int actiondfs_append_cached_child(struct actiondfs_cached_child **children_ptr,
					 size_t *count,
					 size_t *capacity_ptr,
					 const char *name,
					 size_t name_len,
					 umode_t mode,
					 u64 size,
					 const char *hash)
{
	struct actiondfs_cached_child *children;
	struct actiondfs_cached_child *child;
	size_t capacity;
	int err;

	err = actiondfs_valid_component(name, name_len);
	if (err)
		return err;
	err = actiondfs_validate_next_cached_child(*children_ptr, *count,
						   name, name_len);
	if (err)
		return err;

	if (*count == *capacity_ptr) {
		if (*capacity_ptr > SIZE_MAX / 2)
			return -EOVERFLOW;
		capacity = *capacity_ptr ? *capacity_ptr * 2 : 8;
		children = krealloc_array(*children_ptr, capacity,
					  sizeof(*children), GFP_KERNEL);
		if (!children)
			return -ENOMEM;
		*children_ptr = children;
		*capacity_ptr = capacity;
	}

	child = &(*children_ptr)[(*count)++];
	memset(child, 0, sizeof(*child));
	child->name = kmemdup_nul(name, name_len, GFP_KERNEL);
	if (!child->name)
		return -ENOMEM;
	child->name_len = name_len;
	child->mode = mode;
	child->size = size;
	memcpy(child->hash, hash, 64);
	child->hash[64] = '\0';
	return 0;
}

static int actiondfs_append_child(struct actiondfs_node *dir,
				  struct actiondfs_node ***children_ptr,
				  size_t *count,
				  size_t *capacity_ptr,
				  struct actiondfs_node *child)
{
	struct actiondfs_node **children;
	size_t capacity;

	if (!actiondfs_is_dir(dir))
		return -ENOTDIR;

	child->parent = dir;
	if (*count == *capacity_ptr) {
		if (*capacity_ptr > SIZE_MAX / 2)
			return -EOVERFLOW;
		capacity = *capacity_ptr ? *capacity_ptr * 2 : 8;
		children = krealloc_array(*children_ptr, capacity,
					  sizeof(*children), GFP_KERNEL);
		if (!children)
			return -ENOMEM;
		*children_ptr = children;
		*capacity_ptr = capacity;
	}
	(*children_ptr)[(*count)++] = child;
	return 0;
}

static struct actiondfs_node *actiondfs_add_dir_child(struct actiondfs_sb_info *sbi,
						      struct actiondfs_node *parent,
						      const char *name,
						      size_t name_len,
						      const char *hash,
						      bool loaded)
{
	struct actiondfs_node *dir;
	int err;

	err = actiondfs_valid_component(name, name_len);
	if (err)
		return ERR_PTR(err);
	err = actiondfs_validate_next_child(parent->dir_children,
					    parent->dir_count,
					    name, name_len);
	if (err)
		return ERR_PTR(err);

	dir = actiondfs_alloc_node_len(sbi, name, name_len, S_IFDIR | ACTIONDFS_DIR_MODE);
	if (!dir)
		return ERR_PTR(-ENOMEM);

	if (hash) {
		memcpy(dir->hash, hash, 64);
		dir->hash[64] = '\0';
	}
	dir->loaded = loaded;

	err = actiondfs_append_child(parent, &parent->dir_children,
				     &parent->dir_count,
				     &parent->dir_capacity, dir);
	if (err) {
		actiondfs_free_tree(dir);
		return ERR_PTR(err);
	}
	return dir;
}

static int actiondfs_add_file_child(struct actiondfs_sb_info *sbi,
				    struct actiondfs_node *parent,
				    const char *name,
				    size_t name_len,
				    umode_t mode,
				    u64 size,
				    const char *hash)
{
	struct actiondfs_node *file;
	int err;

	err = actiondfs_valid_component(name, name_len);
	if (err)
		return err;
	err = actiondfs_validate_next_child(parent->file_children,
					    parent->file_count,
					    name, name_len);
	if (err)
		return err;

	file = actiondfs_alloc_node_len(sbi, name, name_len, S_IFREG | (mode & 0777));
	if (!file)
		return -ENOMEM;

	file->size = size;
	memcpy(file->hash, hash, 64);
	file->hash[64] = '\0';

	err = actiondfs_append_child(parent, &parent->file_children,
				     &parent->file_count,
				     &parent->file_capacity, file);
	if (err) {
		actiondfs_free_tree(file);
		return err;
	}
	return 0;
}

static int actiondfs_hex_nibble(char c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if (c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

static int actiondfs_valid_hash(const char *hash)
{
	size_t i;

	if (strlen(hash) != 64)
		return -EINVAL;
	for (i = 0; i < 64; i++) {
		if (actiondfs_hex_nibble(hash[i]) < 0)
			return -EINVAL;
	}
	return 0;
}

static bool actiondfs_retry_stale(int err, unsigned int *attempts)
{
	if (err != -ESTALE || *attempts >= ACTIONDFS_STALE_RETRY_ATTEMPTS)
		return false;
	(*attempts)++;
	msleep(ACTIONDFS_STALE_RETRY_MS);
	return true;
}

static struct file *actiondfs_open_cas_blob(struct actiondfs_sb_info *sbi,
					    const char *hash)
{
	unsigned int stale_attempts = 0;
	struct file *file;
	int err;

	while (true) {
		file = file_open_root(&sbi->cas_path, hash, O_RDONLY, 0);
		if (!IS_ERR(file))
			return file;

		err = PTR_ERR(file);
		if (!actiondfs_retry_stale(err, &stale_attempts))
			return file;
	}
}

static void actiondfs_drop_node_blob(struct actiondfs_node *node)
{
	struct file *file = NULL;

	mutex_lock(&node->blob_lock);
	if (node->blob_file) {
		file = node->blob_file;
		node->blob_file = NULL;
	}
	mutex_unlock(&node->blob_lock);

	if (file)
		filp_close(file, NULL);
}

static struct file *actiondfs_get_node_blob(struct actiondfs_sb_info *sbi,
					    struct actiondfs_node *node)
{
	struct file *file;
	int err;

	err = actiondfs_valid_hash(node->hash);
	if (err)
		return ERR_PTR(err);

	mutex_lock(&node->blob_lock);
	file = node->blob_file;
	if (file) {
		get_file(file);
		mutex_unlock(&node->blob_lock);
		return file;
	}

	file = actiondfs_open_cas_blob(sbi, node->hash);
	if (!IS_ERR(file)) {
		node->blob_file = file;
		get_file(file);
	}
	mutex_unlock(&node->blob_lock);
	return file;
}

static int actiondfs_pb_read_varint(const u8 *data, size_t len,
				    size_t *pos, u64 *value)
{
	u64 out = 0;
	unsigned int shift = 0;

	while (*pos < len && shift < 64) {
		u8 byte = data[(*pos)++];

		if (shift == 63 && (byte & 0xfe))
			return -EINVAL;
		out |= (u64)(byte & 0x7f) << shift;
		if (!(byte & 0x80)) {
			*value = out;
			return 0;
		}
		shift += 7;
	}
	return -EINVAL;
}

static int actiondfs_pb_read_len(const u8 *data, size_t len, size_t *pos,
				 const u8 **field, size_t *field_len)
{
	u64 length;
	int err;

	err = actiondfs_pb_read_varint(data, len, pos, &length);
	if (err)
		return err;
	if (length > len - *pos)
		return -EINVAL;
	*field = data + *pos;
	*field_len = length;
	*pos += length;
	return 0;
}

static int actiondfs_pb_skip(const u8 *data, size_t len, size_t *pos, u64 wire)
{
	const u8 *field;
	size_t field_len;
	u64 value;

	switch (wire) {
	case 0:
		return actiondfs_pb_read_varint(data, len, pos, &value);
	case 1:
		if (len - *pos < 8)
			return -EINVAL;
		*pos += 8;
		return 0;
	case 2:
		return actiondfs_pb_read_len(data, len, pos, &field, &field_len);
	case 5:
		if (len - *pos < 4)
			return -EINVAL;
		*pos += 4;
		return 0;
	default:
		return -EINVAL;
	}
}

struct actiondfs_reapi_digest {
	char hash[65];
	u64 size;
	bool has_hash;
};

struct actiondfs_parsed_file {
	const u8 *name;
	size_t name_len;
	struct actiondfs_reapi_digest digest;
	bool executable;
};

struct actiondfs_parsed_dir {
	const u8 *name;
	size_t name_len;
	struct actiondfs_reapi_digest digest;
};

static int actiondfs_parse_reapi_digest(const u8 *data, size_t len,
					struct actiondfs_reapi_digest *digest)
{
	size_t pos = 0;
	int err;

	memset(digest, 0, sizeof(*digest));
	while (pos < len) {
		const u8 *field;
		size_t field_len;
		u64 key;
		u64 value;

		err = actiondfs_pb_read_varint(data, len, &pos, &key);
		if (err)
			return err;

		switch (key >> 3) {
		case 1:
			if ((key & 7) != 2)
				return -EINVAL;
			err = actiondfs_pb_read_len(data, len, &pos, &field, &field_len);
			if (err)
				return err;
			if (field_len != 64)
				return -EINVAL;
			memcpy(digest->hash, field, 64);
			digest->hash[64] = '\0';
			err = actiondfs_valid_hash(digest->hash);
			if (err)
				return err;
			digest->has_hash = true;
			break;
		case 2:
			if ((key & 7) != 0)
				return -EINVAL;
			err = actiondfs_pb_read_varint(data, len, &pos, &value);
			if (err)
				return err;
			digest->size = value;
			break;
		default:
			err = actiondfs_pb_skip(data, len, &pos, key & 7);
			if (err)
				return err;
		}
	}

	return digest->has_hash ? 0 : -EINVAL;
}

static int actiondfs_parse_reapi_file_fields(const u8 *data, size_t len,
					     struct actiondfs_parsed_file *out)
{
	size_t pos = 0;
	bool has_digest = false;
	int err;

	memset(out, 0, sizeof(*out));
	while (pos < len) {
		const u8 *field;
		size_t field_len;
		u64 key;
		u64 value;

		err = actiondfs_pb_read_varint(data, len, &pos, &key);
		if (err)
			return err;

		switch (key >> 3) {
		case 1:
			if ((key & 7) != 2)
				return -EINVAL;
			err = actiondfs_pb_read_len(data, len, &pos, &field, &field_len);
			if (err)
				return err;
			out->name = field;
			out->name_len = field_len;
			break;
		case 2:
			if ((key & 7) != 2)
				return -EINVAL;
			err = actiondfs_pb_read_len(data, len, &pos, &field, &field_len);
			if (err)
				return err;
			err = actiondfs_parse_reapi_digest(field, field_len, &out->digest);
			if (err)
				return err;
			has_digest = true;
			break;
		case 4:
			if ((key & 7) != 0)
				return -EINVAL;
			err = actiondfs_pb_read_varint(data, len, &pos, &value);
			if (err)
				return err;
			out->executable = value != 0;
			break;
		default:
			err = actiondfs_pb_skip(data, len, &pos, key & 7);
			if (err)
				return err;
		}
	}

	return out->name && has_digest ? 0 : -EINVAL;
}

static int actiondfs_parse_reapi_dir_fields(const u8 *data, size_t len,
					    struct actiondfs_parsed_dir *out)
{
	size_t pos = 0;
	bool has_digest = false;
	int err;

	memset(out, 0, sizeof(*out));
	while (pos < len) {
		const u8 *field;
		size_t field_len;
		u64 key;

		err = actiondfs_pb_read_varint(data, len, &pos, &key);
		if (err)
			return err;

		switch (key >> 3) {
		case 1:
			if ((key & 7) != 2)
				return -EINVAL;
			err = actiondfs_pb_read_len(data, len, &pos, &field, &field_len);
			if (err)
				return err;
			out->name = field;
			out->name_len = field_len;
			break;
		case 2:
			if ((key & 7) != 2)
				return -EINVAL;
			err = actiondfs_pb_read_len(data, len, &pos, &field, &field_len);
			if (err)
				return err;
			err = actiondfs_parse_reapi_digest(field, field_len, &out->digest);
			if (err)
				return err;
			has_digest = true;
			break;
		default:
			err = actiondfs_pb_skip(data, len, &pos, key & 7);
			if (err)
				return err;
		}
	}

	return out->name && has_digest ? 0 : -EINVAL;
}

static int actiondfs_parse_reapi_file(struct actiondfs_sb_info *sbi,
				      struct actiondfs_node *parent,
				      const u8 *data, size_t len)
{
	struct actiondfs_parsed_file file;
	int err;

	err = actiondfs_parse_reapi_file_fields(data, len, &file);
	if (err)
		return err;

	return actiondfs_add_file_child(sbi, parent, file.name, file.name_len,
					file.executable ? 0555 : 0444,
					file.digest.size, file.digest.hash);
}

static int actiondfs_parse_reapi_directory_node(struct actiondfs_sb_info *sbi,
						struct actiondfs_node *parent,
						const u8 *data, size_t len)
{
	struct actiondfs_parsed_dir dir;
	int err;

	err = actiondfs_parse_reapi_dir_fields(data, len, &dir);
	if (err)
		return err;

	return PTR_ERR_OR_ZERO(actiondfs_add_dir_child(sbi, parent, dir.name,
						      dir.name_len,
						      dir.digest.hash,
						      false));
}

static int actiondfs_parse_reapi_cached_file(struct actiondfs_cached_dir *parent,
					     const u8 *data, size_t len)
{
	struct actiondfs_parsed_file file;
	int err;

	err = actiondfs_parse_reapi_file_fields(data, len, &file);
	if (err)
		return err;

	return actiondfs_append_cached_child(&parent->file_children,
					     &parent->file_count,
					     &parent->file_capacity,
					     file.name, file.name_len,
					     S_IFREG | (file.executable ? 0555 : 0444),
					     file.digest.size,
					     file.digest.hash);
}

static int actiondfs_parse_reapi_cached_dir(struct actiondfs_cached_dir *parent,
					    const u8 *data, size_t len)
{
	struct actiondfs_parsed_dir dir;
	int err;

	err = actiondfs_parse_reapi_dir_fields(data, len, &dir);
	if (err)
		return err;

	if (actiondfs_valid_hash(dir.digest.hash))
		return -EINVAL;
	return actiondfs_append_cached_child(&parent->dir_children,
					     &parent->dir_count,
					     &parent->dir_capacity,
					     dir.name, dir.name_len,
					     S_IFDIR | ACTIONDFS_DIR_MODE,
					     0,
					     dir.digest.hash);
}

static int actiondfs_read_cas_blob_once(struct actiondfs_sb_info *sbi,
					const char *hash,
					u8 **out,
					size_t *out_len)
{
	struct file *file;
	loff_t pos = 0;
	loff_t size;
	ssize_t nread;
	u8 *buffer;
	int err;

	err = actiondfs_valid_hash(hash);
	if (err)
		return err;

	file = actiondfs_open_cas_blob(sbi, hash);
	if (IS_ERR(file))
		return PTR_ERR(file);

	size = i_size_read(file_inode(file));
	if (size < 0 || size > ACTIONDFS_MAX_DIRECTORY_PROTO_SIZE) {
		filp_close(file, NULL);
		return -EINVAL;
	}

	buffer = kvzalloc((size_t)(size ? size : 1), GFP_KERNEL);
	if (!buffer) {
		filp_close(file, NULL);
		return -ENOMEM;
	}

	nread = kernel_read(file, buffer, (size_t)size, &pos);
	filp_close(file, NULL);
	if (nread < 0) {
		kvfree(buffer);
		return nread;
	}
	if (nread != size) {
		kvfree(buffer);
		return -EIO;
	}

	*out = buffer;
	*out_len = (size_t)size;
	return 0;
}

static int actiondfs_read_cas_blob(struct actiondfs_sb_info *sbi,
				   const char *hash,
				   u8 **out,
				   size_t *out_len)
{
	unsigned int stale_attempts = 0;
	int err;

	while (true) {
		err = actiondfs_read_cas_blob_once(sbi, hash, out, out_len);
		if (!actiondfs_retry_stale(err, &stale_attempts))
			return err;
	}
}

static unsigned long actiondfs_digest_cache_key(const char *hash)
{
	unsigned long key = 0;
	size_t i;

	for (i = 0; i < 2 * sizeof(key); i++)
		key = (key << 4) | actiondfs_hex_nibble(hash[i]);
	return key;
}

static struct actiondfs_cached_dir *actiondfs_find_cached_dir_locked(const char *hash)
{
	struct actiondfs_cached_dir *entry;
	unsigned long key = actiondfs_digest_cache_key(hash);

	hash_for_each_possible(actiondfs_dir_cache, entry, hnode, key) {
		if (!memcmp(entry->hash, hash, 64))
			return entry;
	}
	return NULL;
}

static int actiondfs_build_cached_dir(struct actiondfs_sb_info *sbi,
				      const char *hash,
				      struct actiondfs_cached_dir **out)
{
	struct actiondfs_cached_dir *entry;
	u8 *buffer;
	size_t len;
	size_t pos = 0;
	int err;

	entry = kzalloc(sizeof(*entry), GFP_KERNEL);
	if (!entry)
		return -ENOMEM;
	memcpy(entry->hash, hash, 64);
	entry->hash[64] = '\0';

	err = actiondfs_read_cas_blob(sbi, hash, &buffer, &len);
	if (err)
		goto fail;

	while (pos < len) {
		const u8 *field;
		size_t field_len;
		u64 key;

		err = actiondfs_pb_read_varint(buffer, len, &pos, &key);
		if (err)
			goto out_buffer;

		switch (key >> 3) {
		case 1:
			if ((key & 7) != 2) {
				err = -EINVAL;
				goto out_buffer;
			}
			err = actiondfs_pb_read_len(buffer, len, &pos, &field, &field_len);
			if (err)
				goto out_buffer;
			err = actiondfs_parse_reapi_cached_file(entry, field, field_len);
			if (err)
				goto out_buffer;
			break;
		case 2:
			if ((key & 7) != 2) {
				err = -EINVAL;
				goto out_buffer;
			}
			err = actiondfs_pb_read_len(buffer, len, &pos, &field, &field_len);
			if (err)
				goto out_buffer;
			err = actiondfs_parse_reapi_cached_dir(entry, field, field_len);
			if (err)
				goto out_buffer;
			break;
		case 3:
			err = -EOPNOTSUPP;
			goto out_buffer;
		default:
			err = actiondfs_pb_skip(buffer, len, &pos, key & 7);
			if (err)
				goto out_buffer;
		}
	}

	err = actiondfs_validate_no_cross_type_cached_duplicates(entry);
	if (err)
		goto out_buffer;

	*out = entry;
	entry = NULL;

out_buffer:
	kvfree(buffer);
fail:
	actiondfs_free_cached_dir(entry);
	return err;
}

static int actiondfs_get_cached_dir(struct actiondfs_sb_info *sbi,
				    const char *hash,
				    struct actiondfs_cached_dir **out)
{
	struct actiondfs_cached_dir *entry;
	struct actiondfs_cached_dir *existing;
	unsigned long key;
	int err;

	err = actiondfs_valid_hash(hash);
	if (err)
		return err;

	mutex_lock(&actiondfs_dir_cache_lock);
	entry = actiondfs_find_cached_dir_locked(hash);
	mutex_unlock(&actiondfs_dir_cache_lock);
	if (entry) {
		*out = entry;
		return 0;
	}

	err = actiondfs_build_cached_dir(sbi, hash, &entry);
	if (err)
		return err;

	key = actiondfs_digest_cache_key(hash);
	mutex_lock(&actiondfs_dir_cache_lock);
	existing = actiondfs_find_cached_dir_locked(hash);
	if (existing) {
		mutex_unlock(&actiondfs_dir_cache_lock);
		actiondfs_free_cached_dir(entry);
		*out = existing;
		return 0;
	}
	hash_add(actiondfs_dir_cache, &entry->hnode, key);
	mutex_unlock(&actiondfs_dir_cache_lock);

	*out = entry;
	return 0;
}

static int actiondfs_attach_cached_dir(struct actiondfs_node *dir,
				       struct actiondfs_cached_dir *cached)
{
	if (cached->file_count) {
		dir->file_children = kcalloc(cached->file_count,
					     sizeof(*dir->file_children),
					     GFP_KERNEL);
		if (!dir->file_children)
			return -ENOMEM;
		dir->file_count = cached->file_count;
		dir->file_capacity = cached->file_count;
	}

	if (cached->dir_count) {
		dir->dir_children = kcalloc(cached->dir_count,
					    sizeof(*dir->dir_children),
					    GFP_KERNEL);
		if (!dir->dir_children)
			goto fail;
		dir->dir_count = cached->dir_count;
		dir->dir_capacity = cached->dir_count;
	}

	dir->cached_dir = cached;
	dir->loaded = true;
	return 0;

fail:
	actiondfs_clear_children(dir);
	return -ENOMEM;
}

static int actiondfs_load_reapi_directory_locked(struct actiondfs_sb_info *sbi,
						 struct actiondfs_node *dir)
{
	u8 *buffer;
	size_t len;
	size_t pos = 0;
	int err;

	if (dir->loaded)
		return 0;

	if (sbi->use_dir_cache && dir->parent) {
		struct actiondfs_cached_dir *cached;

		err = actiondfs_get_cached_dir(sbi, dir->hash, &cached);
		if (err)
			return err;
		return actiondfs_attach_cached_dir(dir, cached);
	}

	err = actiondfs_read_cas_blob(sbi, dir->hash, &buffer, &len);
	if (err)
		return err;

	while (pos < len) {
		const u8 *field;
		size_t field_len;
		u64 key;

		err = actiondfs_pb_read_varint(buffer, len, &pos, &key);
		if (err)
			goto out;

		switch (key >> 3) {
		case 1:
			if ((key & 7) != 2) {
				err = -EINVAL;
				goto out;
			}
			err = actiondfs_pb_read_len(buffer, len, &pos, &field, &field_len);
			if (err)
				goto out;
			err = actiondfs_parse_reapi_file(sbi, dir, field, field_len);
			if (err)
				goto out;
			break;
		case 2:
			if ((key & 7) != 2) {
				err = -EINVAL;
				goto out;
			}
			err = actiondfs_pb_read_len(buffer, len, &pos, &field, &field_len);
			if (err)
				goto out;
			err = actiondfs_parse_reapi_directory_node(sbi, dir, field, field_len);
			if (err)
				goto out;
			break;
		case 3:
			err = -EOPNOTSUPP;
			goto out;
		default:
			err = actiondfs_pb_skip(buffer, len, &pos, key & 7);
			if (err)
				goto out;
		}
	}

	err = actiondfs_validate_no_cross_type_duplicates(dir);
	if (err)
		goto out;

	dir->loaded = true;
out:
	if (err)
		actiondfs_clear_children(dir);
	kvfree(buffer);
	return err;
}

static int actiondfs_ensure_loaded(struct super_block *sb,
				   struct actiondfs_node *dir)
{
	struct actiondfs_sb_info *sbi = actiondfs_sbi(sb);
	int err = 0;

	if (!actiondfs_is_dir(dir))
		return -ENOTDIR;
	if (dir->loaded)
		return 0;

	mutex_lock(&sbi->load_lock);
	if (!dir->loaded)
		err = actiondfs_load_reapi_directory_locked(sbi, dir);
	mutex_unlock(&sbi->load_lock);
	return err;
}

static int actiondfs_parse_options(struct actiondfs_sb_info *sbi, void *data)
{
	char *options;
	char *cursor;
	char *token;

	if (!data)
		return -EINVAL;

	options = kstrdup(data, GFP_KERNEL);
	if (!options)
		return -ENOMEM;
	cursor = options;

	while ((token = strsep(&cursor, ",")) != NULL) {
		if (str_has_prefix(token, "root=")) {
			kfree(sbi->root_hash);
			sbi->root_hash = kstrdup(token + 5, GFP_KERNEL);
			if (!sbi->root_hash) {
				kfree(options);
				return -ENOMEM;
			}
		} else if (str_has_prefix(token, "cas=")) {
			kfree(sbi->cas_root);
			sbi->cas_root = kstrdup(token + 4, GFP_KERNEL);
			if (!sbi->cas_root) {
				kfree(options);
				return -ENOMEM;
			}
		} else if (*token) {
			kfree(options);
			return -EINVAL;
		}
	}

	kfree(options);
	if (!sbi->cas_root || !sbi->root_hash)
		return -EINVAL;
	if (actiondfs_valid_hash(sbi->root_hash))
		return -EINVAL;
	if (strchr(sbi->cas_root, ','))
		return -EINVAL;
	return 0;
}

static struct inode *actiondfs_iget(struct super_block *sb,
				    struct actiondfs_node *node)
{
	struct inode *inode;

	inode = iget_locked(sb, node->ino);
	if (!inode)
		return ERR_PTR(-ENOMEM);
	if (!(inode->i_state & I_NEW))
		return inode;

	inode_init_owner(&nop_mnt_idmap, inode, NULL, node->mode);
	inode->i_private = node;
	inode->i_mapping->a_ops = &actiondfs_aops;
	mapping_set_gfp_mask(inode->i_mapping, GFP_HIGHUSER);
	simple_inode_init_ts(inode);

	if (S_ISDIR(node->mode)) {
		inode->i_op = &actiondfs_dir_iops;
		inode->i_fop = &actiondfs_dir_fops;
		set_nlink(inode, 2);
	} else {
		inode->i_op = &actiondfs_file_iops;
		inode->i_fop = &actiondfs_file_fops;
		i_size_write(inode, node->size);
		set_nlink(inode, 1);
	}

	unlock_new_inode(inode);
	return inode;
}

static struct dentry *actiondfs_lookup(struct inode *dir,
				       struct dentry *dentry,
				       unsigned int flags)
{
	struct actiondfs_node *parent = dir->i_private;
	struct actiondfs_node *child;
	struct inode *inode = NULL;
	int err;

	if (dentry->d_name.len > NAME_MAX)
		return ERR_PTR(-ENAMETOOLONG);

	err = actiondfs_ensure_loaded(dir->i_sb, parent);
	if (err)
		return ERR_PTR(err);

	child = actiondfs_lookup_child(actiondfs_sbi(dir->i_sb), parent,
				       dentry->d_name.name, dentry->d_name.len);
	if (IS_ERR(child))
		return ERR_CAST(child);
	if (child) {
		inode = actiondfs_iget(dir->i_sb, child);
		if (IS_ERR(inode))
			return ERR_CAST(inode);
	}

	d_add(dentry, inode);
	return NULL;
}

static int actiondfs_iterate_shared(struct file *file, struct dir_context *ctx)
{
	struct inode *inode = file_inode(file);
	struct actiondfs_node *dir = inode->i_private;
	size_t i;
	loff_t pos = 2;
	int err;

	err = actiondfs_ensure_loaded(inode->i_sb, dir);
	if (err)
		return err;

	if (!dir_emit_dots(file, ctx))
		return 0;

	if (dir->cached_dir) {
		struct actiondfs_cached_dir *cached = dir->cached_dir;

		for (i = 0; i < cached->file_count; i++, pos++) {
			struct actiondfs_cached_child *child = &cached->file_children[i];
			struct actiondfs_node *materialized;
			u64 ino;

			materialized = smp_load_acquire(&dir->file_children[i]);
			ino = materialized ? materialized->ino : 0;

			if (pos < ctx->pos)
				continue;
			if (!dir_emit(ctx, child->name, child->name_len, ino, DT_REG))
				return 0;
			ctx->pos = pos + 1;
		}

		for (i = 0; i < cached->dir_count; i++, pos++) {
			struct actiondfs_cached_child *child = &cached->dir_children[i];
			struct actiondfs_node *materialized;
			u64 ino;

			materialized = smp_load_acquire(&dir->dir_children[i]);
			ino = materialized ? materialized->ino : 0;

			if (pos < ctx->pos)
				continue;
			if (!dir_emit(ctx, child->name, child->name_len, ino, DT_DIR))
				return 0;
			ctx->pos = pos + 1;
		}
		return 0;
	}

	for (i = 0; i < dir->file_count; i++, pos++) {
		struct actiondfs_node *child = dir->file_children[i];

		if (pos < ctx->pos)
			continue;
		if (!dir_emit(ctx, child->name, child->name_len, child->ino, DT_REG))
			return 0;
		ctx->pos = pos + 1;
	}

	for (i = 0; i < dir->dir_count; i++, pos++) {
		struct actiondfs_node *child = dir->dir_children[i];

		if (pos < ctx->pos)
			continue;
		if (!dir_emit(ctx, child->name, child->name_len, child->ino, DT_DIR))
			return 0;
		ctx->pos = pos + 1;
	}
	return 0;
}

static int actiondfs_read_folio(struct file *file, struct folio *folio)
{
	struct inode *inode = file_inode(file);
	struct actiondfs_node *node = inode->i_private;
	struct actiondfs_sb_info *sbi = actiondfs_sbi(inode->i_sb);
	struct file *blob = NULL;
	void *addr;
	loff_t offset = folio_pos(folio);
	size_t folio_len = folio_size(folio);
	size_t wanted = 0;
	ssize_t nread = 0;
	int err = 0;

	addr = kmap_local_folio(folio, 0);
	memset(addr, 0, folio_len);

	if (offset < node->size)
		wanted = min_t(u64, folio_len, node->size - offset);

	if (wanted) {
		unsigned int stale_attempts = 0;

		do {
			loff_t pos = offset;

			blob = actiondfs_get_node_blob(sbi, node);
			if (IS_ERR(blob)) {
				err = PTR_ERR(blob);
				blob = NULL;
			} else {
				nread = kernel_read(blob, addr, wanted, &pos);
				if (nread < 0)
					err = nread;
				else if (nread != wanted)
					err = -EIO;
				else
					err = 0;
				filp_close(blob, NULL);
				blob = NULL;
			}
			if (err == -ESTALE)
				actiondfs_drop_node_blob(node);
		} while (actiondfs_retry_stale(err, &stale_attempts));

		if (err)
			goto out;
	}

	folio_mark_uptodate(folio);

out:
	kunmap_local(addr);
	if (blob)
		filp_close(blob, NULL);
	folio_unlock(folio);
	return err;
}

static const struct address_space_operations actiondfs_aops = {
	.read_folio = actiondfs_read_folio,
};

static const struct inode_operations actiondfs_file_iops = {
	.getattr = simple_getattr,
};

static const struct file_operations actiondfs_file_fops = {
	.llseek = generic_file_llseek,
	.read_iter = generic_file_read_iter,
	.mmap = generic_file_readonly_mmap,
	.splice_read = filemap_splice_read,
};

static const struct inode_operations actiondfs_dir_iops = {
	.lookup = actiondfs_lookup,
	.getattr = simple_getattr,
};

static const struct file_operations actiondfs_dir_fops = {
	.llseek = generic_file_llseek,
	.read = generic_read_dir,
	.iterate_shared = actiondfs_iterate_shared,
};

static void actiondfs_put_super(struct super_block *sb)
{
	struct actiondfs_sb_info *sbi = actiondfs_sbi(sb);

	if (!sbi)
		return;
	actiondfs_free_tree(sbi->root);
	if (sbi->cas_path_valid)
		path_put(&sbi->cas_path);
	kfree(sbi->cas_root);
	kfree(sbi->root_hash);
	kfree(sbi);
	sb->s_fs_info = NULL;
}

static const struct super_operations actiondfs_super_ops = {
	.statfs = simple_statfs,
	.put_super = actiondfs_put_super,
};

static int actiondfs_fill_super_mode(struct super_block *sb, void *data,
				     int silent,
				     enum actiondfs_lookup_mode lookup_mode,
				     bool use_dir_cache)
{
	struct actiondfs_sb_info *sbi;
	struct inode *root_inode;
	int err;

	sbi = kzalloc(sizeof(*sbi), GFP_KERNEL);
	if (!sbi)
		return -ENOMEM;

	sb->s_fs_info = sbi;
	sbi->lookup_mode = lookup_mode;
	sbi->use_dir_cache = use_dir_cache;
	mutex_init(&sbi->load_lock);
	sb->s_magic = ACTIONDFS_MAGIC;
	sb->s_maxbytes = MAX_LFS_FILESIZE;
	sb->s_blocksize = PAGE_SIZE;
	sb->s_blocksize_bits = PAGE_SHIFT;
	sb->s_flags |= SB_RDONLY | SB_NOATIME;
	sb->s_op = &actiondfs_super_ops;
	sb->s_time_gran = 1;

	sbi->root = actiondfs_alloc_node(sbi, "", S_IFDIR | ACTIONDFS_DIR_MODE);
	if (!sbi->root) {
		err = -ENOMEM;
		goto fail;
	}

	err = actiondfs_parse_options(sbi, data);
	if (err)
		goto fail;
	err = kern_path(sbi->cas_root, LOOKUP_FOLLOW | LOOKUP_DIRECTORY, &sbi->cas_path);
	if (err)
		goto fail;
	sbi->cas_path_valid = true;
	memcpy(sbi->root->hash, sbi->root_hash, 64);
	sbi->root->hash[64] = '\0';
	sbi->root->loaded = false;

	root_inode = actiondfs_iget(sb, sbi->root);
	if (IS_ERR(root_inode)) {
		err = PTR_ERR(root_inode);
		goto fail;
	}

	sb->s_root = d_make_root(root_inode);
	if (!sb->s_root) {
		err = -ENOMEM;
		goto fail;
	}
	return 0;

fail:
	actiondfs_put_super(sb);
	return err;
}

static int actiondfs_fill_super(struct super_block *sb, void *data, int silent)
{
	return actiondfs_fill_super_mode(sb, data, silent,
					 ACTIONDFS_LOOKUP_CANONICAL, true);
}

static int actiondfs_old_fill_super(struct super_block *sb, void *data, int silent)
{
	return actiondfs_fill_super_mode(sb, data, silent,
					 ACTIONDFS_LOOKUP_CANONICAL, false);
}

static int actiondfs_vec_fill_super(struct super_block *sb, void *data, int silent)
{
	return actiondfs_fill_super_mode(sb, data, silent,
					 ACTIONDFS_LOOKUP_HYBRID32, true);
}

static int actiondfs_hybrid32_fill_super(struct super_block *sb, void *data, int silent)
{
	return actiondfs_fill_super_mode(sb, data, silent,
					 ACTIONDFS_LOOKUP_HYBRID32, true);
}

static struct dentry *actiondfs_mount(struct file_system_type *fs_type,
				      int flags,
				      const char *dev_name,
				      void *data)
{
	return mount_nodev(fs_type, flags | SB_RDONLY, data, actiondfs_fill_super);
}

static struct dentry *actiondfs_old_mount(struct file_system_type *fs_type,
					  int flags,
					  const char *dev_name,
					  void *data)
{
	return mount_nodev(fs_type, flags | SB_RDONLY, data,
			   actiondfs_old_fill_super);
}

static struct dentry *actiondfs_vec_mount(struct file_system_type *fs_type,
					  int flags,
					  const char *dev_name,
					  void *data)
{
	return mount_nodev(fs_type, flags | SB_RDONLY, data,
			   actiondfs_vec_fill_super);
}

static struct dentry *actiondfs_hybrid32_mount(struct file_system_type *fs_type,
					       int flags,
					       const char *dev_name,
					       void *data)
{
	return mount_nodev(fs_type, flags | SB_RDONLY, data,
			   actiondfs_hybrid32_fill_super);
}

static struct file_system_type actiondfs_fs_type = {
	.owner = THIS_MODULE,
	.name = "actiondfs",
	.mount = actiondfs_mount,
	.kill_sb = kill_anon_super,
};

static struct file_system_type actiondfs_old_fs_type = {
	.owner = THIS_MODULE,
	.name = "actiondfs_old",
	.mount = actiondfs_old_mount,
	.kill_sb = kill_anon_super,
};

static struct file_system_type actiondfs_vec_fs_type = {
	.owner = THIS_MODULE,
	.name = "actiondfs_vec",
	.mount = actiondfs_vec_mount,
	.kill_sb = kill_anon_super,
};

static struct file_system_type actiondfs_hybrid32_fs_type = {
	.owner = THIS_MODULE,
	.name = "actiondfs_hybrid32",
	.mount = actiondfs_hybrid32_mount,
	.kill_sb = kill_anon_super,
};

static struct file_system_type *actiondfs_fs_types[] = {
	&actiondfs_fs_type,
	&actiondfs_old_fs_type,
	&actiondfs_vec_fs_type,
	&actiondfs_hybrid32_fs_type,
};

static int __init actiondfs_init(void)
{
	size_t i;
	int err;

	for (i = 0; i < ARRAY_SIZE(actiondfs_fs_types); i++) {
		err = register_filesystem(actiondfs_fs_types[i]);
		if (err)
			goto fail;
	}
	return 0;

fail:
	while (i > 0)
		unregister_filesystem(actiondfs_fs_types[--i]);
	return err;
}

static void __exit actiondfs_exit(void)
{
	size_t i;

	for (i = ARRAY_SIZE(actiondfs_fs_types); i > 0; i--)
		unregister_filesystem(actiondfs_fs_types[i - 1]);
	actiondfs_destroy_dir_cache();
}

module_init(actiondfs_init);
module_exit(actiondfs_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("actiond manifest filesystem");
