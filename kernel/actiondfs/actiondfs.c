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

#include <linux/backing-file.h>
#include <linux/cred.h>
#include <linux/delay.h>
#include <linux/err.h>
#include <linux/file.h>
#include <linux/fs.h>
#include <linux/fs_context.h>
#include <linux/hashtable.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/list.h>
#include <linux/magic.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/mount.h>
#include <linux/mutex.h>
#include <linux/namei.h>
#include <linux/parser.h>
#include <linux/path.h>
#include <linux/proc_fs.h>
#include <linux/rcupdate.h>
#include <linux/seq_file.h>
#include <linux/slab.h>
#include <linux/splice.h>
#include <linux/statfs.h>
#include <linux/string.h>
#include <linux/uaccess.h>
#include <linux/uio.h>
#include <linux/vmalloc.h>

#define ACTIONDFS_MAGIC 0x41444653
#define ACTIONDFS_MAX_DIRECTORY_PROTO_SIZE (64U * 1024U * 1024U)
#define ACTIONDFS_DIR_MODE 0777
#define ACTIONDFS_STALE_RETRY_ATTEMPTS 128
#define ACTIONDFS_STALE_RETRY_MS 2
#define ACTIONDFS_DIR_CACHE_BITS 12
#define ACTIONDFS_BLOB_PATH_CACHE_BITS 14
#define ACTIONDFS_BLOB_PATH_CACHE_MAX 16384
#define ACTIONDFS_PROC_STATS "actiondfs_stats"
#define ACTIONDFS_HASH_HEX_LEN 64
#define ACTIONDFS_SHARDED_HASH_PATH_LEN (2 + 1 + ACTIONDFS_HASH_HEX_LEN)

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

struct actiondfs_blob_path_cache_entry {
	struct hlist_node hnode;
	struct list_head list;
	char hash[65];
	struct path path;
	atomic_t hits;
};

struct actiondfs_materialized_child {
	bool is_dir;
	size_t index;
	struct actiondfs_node *node;
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
	struct actiondfs_materialized_child *materialized_children;
	size_t materialized_count;
	size_t materialized_capacity;
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
	struct mutex load_lock;
};

enum actiondfs_stat {
	ACTIONDFS_STAT_MOUNTS,
	ACTIONDFS_STAT_DIR_LOADS,
	ACTIONDFS_STAT_ROOT_DIR_PARSES,
	ACTIONDFS_STAT_CACHED_DIR_REQUESTS,
	ACTIONDFS_STAT_DIR_CACHE_HITS,
	ACTIONDFS_STAT_DIR_CACHE_MISSES,
	ACTIONDFS_STAT_DIR_CACHE_RACES,
	ACTIONDFS_STAT_CACHED_DIR_BUILDS,
	ACTIONDFS_STAT_CACHED_DIR_BYTES,
	ACTIONDFS_STAT_CACHED_FILE_RECORDS,
	ACTIONDFS_STAT_CACHED_DIR_RECORDS,
	ACTIONDFS_STAT_DIRECT_FILE_NODES,
	ACTIONDFS_STAT_DIRECT_DIR_NODES,
	ACTIONDFS_STAT_LOOKUPS,
	ACTIONDFS_STAT_LOOKUP_HITS,
	ACTIONDFS_STAT_LOOKUP_NEGATIVE,
	ACTIONDFS_STAT_CACHED_LOOKUPS,
	ACTIONDFS_STAT_CACHED_LOOKUP_HITS,
	ACTIONDFS_STAT_CACHED_MATERIALIZED,
	ACTIONDFS_STAT_CACHED_REUSED,
	ACTIONDFS_STAT_READDIRS,
	ACTIONDFS_STAT_READDIR_ENTRIES,
	ACTIONDFS_STAT_READDIR_RESUMES,
	ACTIONDFS_STAT_READDIR_SKIPPED_ENTRIES_AVOIDED,
	ACTIONDFS_STAT_BLOB_OPEN_ATTEMPTS,
	ACTIONDFS_STAT_BLOB_OPEN_STALE_RETRIES,
	ACTIONDFS_STAT_BLOB_PATH_CACHE_HITS,
	ACTIONDFS_STAT_BLOB_PATH_CACHE_MISSES,
	ACTIONDFS_STAT_BLOB_PATH_CACHE_INSERTS,
	ACTIONDFS_STAT_BLOB_PATH_CACHE_EVICTIONS,
	ACTIONDFS_STAT_BLOB_PATH_CACHE_RACES,
	ACTIONDFS_STAT_NODE_BLOB_CACHE_HITS,
	ACTIONDFS_STAT_NODE_BLOB_CACHE_MISSES,
	ACTIONDFS_STAT_BACKING_READS,
	ACTIONDFS_STAT_BACKING_READ_BYTES,
	ACTIONDFS_STAT_BACKING_READ_STALE_RETRIES,
	ACTIONDFS_STAT_SPLICE_READS,
	ACTIONDFS_STAT_SPLICE_READ_BYTES,
	ACTIONDFS_STAT_SPLICE_READ_STALE_RETRIES,
	ACTIONDFS_STAT_MMAPS,
	ACTIONDFS_STAT_MMAP_BYTES,
	ACTIONDFS_STAT_MMAP_FAILURES,
	ACTIONDFS_STAT_DIRECTORY_BLOB_READS,
	ACTIONDFS_STAT_DIRECTORY_BLOB_BYTES,
	ACTIONDFS_STAT_COUNT,
};

static const char * const actiondfs_stat_names[ACTIONDFS_STAT_COUNT] = {
	[ACTIONDFS_STAT_MOUNTS] = "mounts",
	[ACTIONDFS_STAT_DIR_LOADS] = "dir_loads",
	[ACTIONDFS_STAT_ROOT_DIR_PARSES] = "root_dir_parses",
	[ACTIONDFS_STAT_CACHED_DIR_REQUESTS] = "cached_dir_requests",
	[ACTIONDFS_STAT_DIR_CACHE_HITS] = "dir_cache_hits",
	[ACTIONDFS_STAT_DIR_CACHE_MISSES] = "dir_cache_misses",
	[ACTIONDFS_STAT_DIR_CACHE_RACES] = "dir_cache_races",
	[ACTIONDFS_STAT_CACHED_DIR_BUILDS] = "cached_dir_builds",
	[ACTIONDFS_STAT_CACHED_DIR_BYTES] = "cached_dir_bytes",
	[ACTIONDFS_STAT_CACHED_FILE_RECORDS] = "cached_file_records",
	[ACTIONDFS_STAT_CACHED_DIR_RECORDS] = "cached_dir_records",
	[ACTIONDFS_STAT_DIRECT_FILE_NODES] = "direct_file_nodes",
	[ACTIONDFS_STAT_DIRECT_DIR_NODES] = "direct_dir_nodes",
	[ACTIONDFS_STAT_LOOKUPS] = "lookups",
	[ACTIONDFS_STAT_LOOKUP_HITS] = "lookup_hits",
	[ACTIONDFS_STAT_LOOKUP_NEGATIVE] = "lookup_negative",
	[ACTIONDFS_STAT_CACHED_LOOKUPS] = "cached_lookups",
	[ACTIONDFS_STAT_CACHED_LOOKUP_HITS] = "cached_lookup_hits",
	[ACTIONDFS_STAT_CACHED_MATERIALIZED] = "cached_materialized",
	[ACTIONDFS_STAT_CACHED_REUSED] = "cached_reused",
	[ACTIONDFS_STAT_READDIRS] = "readdirs",
	[ACTIONDFS_STAT_READDIR_ENTRIES] = "readdir_entries",
	[ACTIONDFS_STAT_READDIR_RESUMES] = "readdir_resumes",
	[ACTIONDFS_STAT_READDIR_SKIPPED_ENTRIES_AVOIDED] = "readdir_skipped_entries_avoided",
	[ACTIONDFS_STAT_BLOB_OPEN_ATTEMPTS] = "blob_open_attempts",
	[ACTIONDFS_STAT_BLOB_OPEN_STALE_RETRIES] = "blob_open_stale_retries",
	[ACTIONDFS_STAT_BLOB_PATH_CACHE_HITS] = "blob_path_cache_hits",
	[ACTIONDFS_STAT_BLOB_PATH_CACHE_MISSES] = "blob_path_cache_misses",
	[ACTIONDFS_STAT_BLOB_PATH_CACHE_INSERTS] = "blob_path_cache_inserts",
	[ACTIONDFS_STAT_BLOB_PATH_CACHE_EVICTIONS] = "blob_path_cache_evictions",
	[ACTIONDFS_STAT_BLOB_PATH_CACHE_RACES] = "blob_path_cache_races",
	[ACTIONDFS_STAT_NODE_BLOB_CACHE_HITS] = "node_blob_cache_hits",
	[ACTIONDFS_STAT_NODE_BLOB_CACHE_MISSES] = "node_blob_cache_misses",
	[ACTIONDFS_STAT_BACKING_READS] = "backing_reads",
	[ACTIONDFS_STAT_BACKING_READ_BYTES] = "backing_read_bytes",
	[ACTIONDFS_STAT_BACKING_READ_STALE_RETRIES] = "backing_read_stale_retries",
	[ACTIONDFS_STAT_SPLICE_READS] = "splice_reads",
	[ACTIONDFS_STAT_SPLICE_READ_BYTES] = "splice_read_bytes",
	[ACTIONDFS_STAT_SPLICE_READ_STALE_RETRIES] = "splice_read_stale_retries",
	[ACTIONDFS_STAT_MMAPS] = "mmaps",
	[ACTIONDFS_STAT_MMAP_BYTES] = "mmap_bytes",
	[ACTIONDFS_STAT_MMAP_FAILURES] = "mmap_failures",
	[ACTIONDFS_STAT_DIRECTORY_BLOB_READS] = "directory_blob_reads",
	[ACTIONDFS_STAT_DIRECTORY_BLOB_BYTES] = "directory_blob_bytes",
};

static atomic64_t actiondfs_stats[ACTIONDFS_STAT_COUNT];

static void actiondfs_stat_inc(enum actiondfs_stat stat)
{
	atomic64_inc(&actiondfs_stats[stat]);
}

static void actiondfs_stat_add(enum actiondfs_stat stat, u64 value)
{
	atomic64_add(value, &actiondfs_stats[stat]);
}

/*
 * Directory protos are content-addressed and immutable. Keep a VM-lifetime
 * parsed metadata cache for non-root directories so repeated tree artifacts
 * don't re-read and re-parse the same CAS blob for every action mount.
 */
static DEFINE_HASHTABLE(actiondfs_dir_cache, ACTIONDFS_DIR_CACHE_BITS);
static DEFINE_MUTEX(actiondfs_dir_cache_lock);

/*
 * File content nodes are per action mount, but the backing CAS files are
 * content-addressed and heavily reused across mounts. Cache resolved CAS paths
 * by digest, then still call backing_file_open() per actiondfs file so mmap and
 * /proc keep the correct user-visible actiondfs path. Hits use RCU because
 * compilers can open hundreds of thousands of already-resolved CAS blobs across
 * one LLVM build; misses and eviction remain serialized under the cache mutex.
 */
static DEFINE_HASHTABLE(actiondfs_blob_path_cache, ACTIONDFS_BLOB_PATH_CACHE_BITS);
static LIST_HEAD(actiondfs_blob_path_cache_list);
static DEFINE_MUTEX(actiondfs_blob_path_cache_lock);
static size_t actiondfs_blob_path_cache_count;

static const struct inode_operations actiondfs_dir_iops;
static const struct inode_operations actiondfs_file_iops;
static const struct file_operations actiondfs_dir_fops;
static const struct file_operations actiondfs_file_fops;
static size_t actiondfs_readdir_start_index(loff_t ctx_pos, loff_t base,
					    size_t count);
static size_t actiondfs_readdir_start_index_counted(loff_t ctx_pos,
						    loff_t base, size_t count);
static int actiondfs_get_cached_blob_path(struct actiondfs_sb_info *sbi,
					  const char *hash,
					  struct path *out);
static void actiondfs_drop_cached_blob_path(const char *hash);

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

	for (i = 0; i < node->materialized_count; i++)
		actiondfs_free_tree(node->materialized_children[i].node);
	for (i = 0; i < node->file_count; i++)
		actiondfs_free_tree(node->file_children[i]);
	for (i = 0; i < node->dir_count; i++)
		actiondfs_free_tree(node->dir_children[i]);

	kfree(node->materialized_children);
	kfree(node->file_children);
	kfree(node->dir_children);
	if (!node->name_borrowed)
		kfree(node->name);
	if (node->blob_file)
		fput(node->blob_file);
	kfree(node);
}

static void actiondfs_clear_children(struct actiondfs_node *node)
{
	size_t i;

	for (i = 0; i < node->materialized_count; i++)
		actiondfs_free_tree(node->materialized_children[i].node);
	for (i = 0; i < node->file_count; i++)
		actiondfs_free_tree(node->file_children[i]);
	for (i = 0; i < node->dir_count; i++)
		actiondfs_free_tree(node->dir_children[i]);
	kfree(node->materialized_children);
	kfree(node->file_children);
	kfree(node->dir_children);
	node->materialized_children = NULL;
	node->materialized_count = 0;
	node->materialized_capacity = 0;
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

static struct actiondfs_node *actiondfs_find_child_in(struct actiondfs_node **children,
						      size_t count,
						      const char *name,
						      size_t len)
{
	size_t lo = 0;
	size_t hi = count;

	while (lo < hi) {
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
	return NULL;
}

static struct actiondfs_node *actiondfs_find_child(struct actiondfs_node *dir,
						   const char *name,
						   size_t len)
{
	struct actiondfs_node *child;

	child = actiondfs_find_child_in(dir->file_children, dir->file_count,
					name, len);
	if (child)
		return child;
	return actiondfs_find_child_in(dir->dir_children, dir->dir_count,
				       name, len);
}

static bool actiondfs_find_cached_child_in(struct actiondfs_cached_child *children,
					   size_t count,
					   const char *name,
					   size_t len,
					   size_t *out)
{
	size_t lo = 0;
	size_t hi = count;

	while (lo < hi) {
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
	return false;
}

static struct actiondfs_node *
actiondfs_find_materialized_child(struct actiondfs_node *dir,
				  bool is_dir,
				  size_t index)
{
	size_t i;

	for (i = 0; i < dir->materialized_count; i++) {
		struct actiondfs_materialized_child *child = &dir->materialized_children[i];

		if (child->is_dir == is_dir && child->index == index)
			return child->node;
	}
	return NULL;
}

static int actiondfs_append_materialized_child(struct actiondfs_node *dir,
					       bool is_dir,
					       size_t index,
					       struct actiondfs_node *node)
{
	struct actiondfs_materialized_child *children;
	size_t capacity;

	if (dir->materialized_count == dir->materialized_capacity) {
		if (dir->materialized_capacity > SIZE_MAX / 2)
			return -EOVERFLOW;
		capacity = dir->materialized_capacity ? dir->materialized_capacity * 2 : 8;
		children = krealloc_array(dir->materialized_children, capacity,
					  sizeof(*children), GFP_KERNEL);
		if (!children)
			return -ENOMEM;
		dir->materialized_children = children;
		dir->materialized_capacity = capacity;
	}

	dir->materialized_children[dir->materialized_count++] =
		(struct actiondfs_materialized_child){
			.is_dir = is_dir,
			.index = index,
			.node = node,
		};
	return 0;
}

static struct actiondfs_node *
actiondfs_materialize_cached_child(struct actiondfs_sb_info *sbi,
				   struct actiondfs_node *parent,
				   struct actiondfs_cached_child *record,
				   bool is_dir,
				   size_t index)
{
	struct actiondfs_node *existing;
	struct actiondfs_node *node;
	int err;

	existing = actiondfs_find_materialized_child(parent, is_dir, index);
	if (existing) {
		actiondfs_stat_inc(ACTIONDFS_STAT_CACHED_REUSED);
		return existing;
	}

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

	err = actiondfs_append_materialized_child(parent, is_dir, index, node);
	if (err) {
		actiondfs_free_tree(node);
		return ERR_PTR(err);
	}
	actiondfs_stat_inc(ACTIONDFS_STAT_CACHED_MATERIALIZED);
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

	actiondfs_stat_inc(ACTIONDFS_STAT_CACHED_LOOKUPS);
	if (actiondfs_find_cached_child_in(cached->file_children,
					   cached->file_count,
					   name, len,
					   &index)) {
		actiondfs_stat_inc(ACTIONDFS_STAT_CACHED_LOOKUP_HITS);
		return actiondfs_materialize_cached_child(sbi, dir,
							  &cached->file_children[index],
							  false, index);
	}

	if (actiondfs_find_cached_child_in(cached->dir_children,
					   cached->dir_count,
					   name, len,
					   &index)) {
		actiondfs_stat_inc(ACTIONDFS_STAT_CACHED_LOOKUP_HITS);
		return actiondfs_materialize_cached_child(sbi, dir,
							  &cached->dir_children[index],
							  true, index);
	}

	return NULL;
}

static struct actiondfs_node *actiondfs_lookup_child(struct actiondfs_sb_info *sbi,
						     struct actiondfs_node *dir,
						     const char *name,
						     size_t len)
{
	struct actiondfs_node *child;

	if (!dir->cached_dir)
		return actiondfs_find_child(dir, name, len);

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

static void actiondfs_free_blob_path_cache_entry(struct actiondfs_blob_path_cache_entry *entry)
{
	path_put(&entry->path);
	kfree(entry);
}

static void actiondfs_destroy_blob_path_cache(void)
{
	struct actiondfs_blob_path_cache_entry *entry;
	struct actiondfs_blob_path_cache_entry *tmp_entry;
	struct hlist_node *tmp;
	unsigned int bucket;
	LIST_HEAD(dispose);

	mutex_lock(&actiondfs_blob_path_cache_lock);
	hash_for_each_safe(actiondfs_blob_path_cache, bucket, tmp, entry, hnode) {
		hash_del_rcu(&entry->hnode);
		list_del(&entry->list);
		list_add_tail(&entry->list, &dispose);
		actiondfs_blob_path_cache_count--;
	}
	mutex_unlock(&actiondfs_blob_path_cache_lock);

	synchronize_rcu();
	list_for_each_entry_safe(entry, tmp_entry, &dispose, list) {
		list_del(&entry->list);
		actiondfs_free_blob_path_cache_entry(entry);
	}
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

static int actiondfs_append_cached_file_child(struct actiondfs_cached_dir *parent,
					      const char *name,
					      size_t name_len,
					      umode_t mode,
					      u64 size,
					      const char *hash)
{
	int err;

	err = actiondfs_append_cached_child(&parent->file_children,
					    &parent->file_count,
					    &parent->file_capacity,
					    name, name_len, mode, size, hash);
	if (!err)
		actiondfs_stat_inc(ACTIONDFS_STAT_CACHED_FILE_RECORDS);
	return err;
}

static int actiondfs_append_cached_dir_child(struct actiondfs_cached_dir *parent,
					     const char *name,
					     size_t name_len,
					     umode_t mode,
					     const char *hash)
{
	int err;

	err = actiondfs_append_cached_child(&parent->dir_children,
					    &parent->dir_count,
					    &parent->dir_capacity,
					    name, name_len, mode, 0, hash);
	if (!err)
		actiondfs_stat_inc(ACTIONDFS_STAT_CACHED_DIR_RECORDS);
	return err;
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
	actiondfs_stat_inc(ACTIONDFS_STAT_DIRECT_DIR_NODES);
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
	actiondfs_stat_inc(ACTIONDFS_STAT_DIRECT_FILE_NODES);
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

	if (strlen(hash) != ACTIONDFS_HASH_HEX_LEN)
		return -EINVAL;
	for (i = 0; i < ACTIONDFS_HASH_HEX_LEN; i++) {
		if (actiondfs_hex_nibble(hash[i]) < 0)
			return -EINVAL;
	}
	return 0;
}

static void actiondfs_sharded_hash_path(const char *hash,
					char out[ACTIONDFS_SHARDED_HASH_PATH_LEN + 1])
{
	memcpy(out, hash, 2);
	out[2] = '/';
	memcpy(out + 3, hash, ACTIONDFS_HASH_HEX_LEN);
	out[ACTIONDFS_SHARDED_HASH_PATH_LEN] = '\0';
}

static bool actiondfs_retry_stale(int err, unsigned int *attempts)
{
	if (err != -ESTALE || *attempts >= ACTIONDFS_STALE_RETRY_ATTEMPTS)
		return false;
	(*attempts)++;
	msleep(ACTIONDFS_STALE_RETRY_MS);
	return true;
}

static bool actiondfs_retry_open_stale(int err, unsigned int *attempts)
{
	if (!actiondfs_retry_stale(err, attempts))
		return false;
	actiondfs_stat_inc(ACTIONDFS_STAT_BLOB_OPEN_STALE_RETRIES);
	return true;
}

static bool actiondfs_retry_backing_read_stale(int err, unsigned int *attempts)
{
	if (!actiondfs_retry_stale(err, attempts))
		return false;
	actiondfs_stat_inc(ACTIONDFS_STAT_BACKING_READ_STALE_RETRIES);
	return true;
}

static bool actiondfs_retry_splice_read_stale(int err, unsigned int *attempts)
{
	if (!actiondfs_retry_stale(err, attempts))
		return false;
	actiondfs_stat_inc(ACTIONDFS_STAT_SPLICE_READ_STALE_RETRIES);
	return true;
}

static struct file *actiondfs_open_directory_blob(struct actiondfs_sb_info *sbi,
						 const char *hash)
{
	unsigned int stale_attempts = 0;
	char path[ACTIONDFS_SHARDED_HASH_PATH_LEN + 1];
	struct file *file;
	int err;

	actiondfs_sharded_hash_path(hash, path);
	while (true) {
		actiondfs_stat_inc(ACTIONDFS_STAT_BLOB_OPEN_ATTEMPTS);
		file = file_open_root(&sbi->cas_path, path, O_RDONLY, 0);
		if (!IS_ERR(file))
			return file;

		err = PTR_ERR(file);
		if (!actiondfs_retry_open_stale(err, &stale_attempts))
			return file;
	}
}

static struct file *actiondfs_open_backing_cas_blob(struct actiondfs_sb_info *sbi,
						    const char *hash,
						    const struct path *user_path)
{
	unsigned int stale_attempts = 0;
	struct file *file;
	struct path real_path;
	int err;

	while (true) {
		actiondfs_stat_inc(ACTIONDFS_STAT_BLOB_OPEN_ATTEMPTS);
		err = actiondfs_get_cached_blob_path(sbi, hash, &real_path);
		if (err) {
			if (!actiondfs_retry_open_stale(err, &stale_attempts))
				return ERR_PTR(err);
			continue;
		}

		file = backing_file_open(user_path, O_RDONLY, &real_path,
					 current_cred());
		path_put(&real_path);
		if (!IS_ERR(file))
			return file;

		err = PTR_ERR(file);
		if (err == -ESTALE)
			actiondfs_drop_cached_blob_path(hash);
		if (!actiondfs_retry_open_stale(err, &stale_attempts))
			return file;
	}
}

static struct file *actiondfs_get_node_blob_file(struct actiondfs_sb_info *sbi,
						 struct actiondfs_node *node,
						 struct file *actiondfs_file)
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
		actiondfs_stat_inc(ACTIONDFS_STAT_NODE_BLOB_CACHE_HITS);
		mutex_unlock(&node->blob_lock);
		return file;
	}

	actiondfs_stat_inc(ACTIONDFS_STAT_NODE_BLOB_CACHE_MISSES);
	file = actiondfs_open_backing_cas_blob(sbi, node->hash,
					       file_user_path(actiondfs_file));
	if (IS_ERR(file)) {
		mutex_unlock(&node->blob_lock);
		return file;
	}

	node->blob_file = file;
	get_file(file);
	mutex_unlock(&node->blob_lock);
	return file;
}

static void actiondfs_drop_node_blob_if_current(struct actiondfs_node *node,
						struct file *current_file)
{
	struct file *file = NULL;

	mutex_lock(&node->blob_lock);
	if (node->blob_file == current_file) {
		file = node->blob_file;
		node->blob_file = NULL;
	}
	mutex_unlock(&node->blob_lock);

	if (file)
		fput(file);
}

static ssize_t actiondfs_read_iter(struct kiocb *iocb, struct iov_iter *to)
{
	struct inode *inode = file_inode(iocb->ki_filp);
	struct actiondfs_node *node = inode->i_private;
	struct actiondfs_sb_info *sbi = actiondfs_sbi(inode->i_sb);
	struct file *file;
	size_t requested = iov_iter_count(to);
	size_t wanted;
	ssize_t nread;
	unsigned int stale_attempts = 0;
	struct backing_file_ctx ctx = {
		.cred = current_cred(),
		.accessed = file_accessed,
	};

	if (!requested)
		return 0;
	if (iocb->ki_pos < 0)
		return -EINVAL;
	if (iocb->ki_pos >= node->size)
		return 0;

	wanted = min_t(u64, (u64)requested, node->size - iocb->ki_pos);
	iov_iter_truncate(to, wanted);

	do {
		file = actiondfs_get_node_blob_file(sbi, node, iocb->ki_filp);
		if (IS_ERR(file))
			return PTR_ERR(file);

		actiondfs_stat_inc(ACTIONDFS_STAT_BACKING_READS);
		nread = backing_file_read_iter(file, to, iocb, iocb->ki_flags,
					       &ctx);
		if (nread == -ESTALE)
			actiondfs_drop_node_blob_if_current(node, file);
		fput(file);
	} while (actiondfs_retry_backing_read_stale(nread, &stale_attempts));

	if (nread > 0)
		actiondfs_stat_add(ACTIONDFS_STAT_BACKING_READ_BYTES, (u64)nread);
	return nread;
}

static ssize_t actiondfs_splice_read(struct file *actiondfs_file, loff_t *ppos,
				     struct pipe_inode_info *pipe, size_t len,
				     unsigned int flags)
{
	struct inode *inode = file_inode(actiondfs_file);
	struct actiondfs_node *node = inode->i_private;
	struct actiondfs_sb_info *sbi = actiondfs_sbi(inode->i_sb);
	struct file *file;
	loff_t pos = *ppos;
	size_t wanted;
	ssize_t nread;
	unsigned int stale_attempts = 0;
	struct backing_file_ctx ctx = {
		.cred = current_cred(),
		.accessed = file_accessed,
	};

	if (!len)
		return 0;
	if (pos < 0)
		return -EINVAL;
	if (pos >= node->size)
		return 0;

	wanted = min_t(u64, (u64)len, node->size - pos);

	do {
		struct kiocb backing_iocb;

		file = actiondfs_get_node_blob_file(sbi, node, actiondfs_file);
		if (IS_ERR(file))
			return PTR_ERR(file);

		init_sync_kiocb(&backing_iocb, actiondfs_file);
		backing_iocb.ki_pos = pos;
		actiondfs_stat_inc(ACTIONDFS_STAT_SPLICE_READS);
		nread = backing_file_splice_read(file, &backing_iocb, pipe,
						 wanted, flags, &ctx);
		if (nread > 0)
			pos = backing_iocb.ki_pos;
		if (nread == -ESTALE)
			actiondfs_drop_node_blob_if_current(node, file);
		fput(file);
	} while (actiondfs_retry_splice_read_stale(nread, &stale_attempts));

	if (nread > 0) {
		*ppos = pos;
		actiondfs_stat_add(ACTIONDFS_STAT_SPLICE_READ_BYTES, (u64)nread);
	}
	return nread;
}

static int actiondfs_mmap(struct file *actiondfs_file,
			  struct vm_area_struct *vma)
{
	struct inode *inode = file_inode(actiondfs_file);
	struct actiondfs_node *node = inode->i_private;
	struct actiondfs_sb_info *sbi = actiondfs_sbi(inode->i_sb);
	struct file *file;
	int err;
	struct backing_file_ctx ctx = {
		.cred = current_cred(),
		.accessed = file_accessed,
	};

	file = actiondfs_get_node_blob_file(sbi, node, actiondfs_file);
	if (IS_ERR(file)) {
		actiondfs_stat_inc(ACTIONDFS_STAT_MMAP_FAILURES);
		return PTR_ERR(file);
	}

	actiondfs_stat_inc(ACTIONDFS_STAT_MMAPS);
	actiondfs_stat_add(ACTIONDFS_STAT_MMAP_BYTES,
			   (u64)(vma->vm_end - vma->vm_start));
	err = backing_file_mmap(file, vma, &ctx);
	if (err) {
		actiondfs_stat_inc(ACTIONDFS_STAT_MMAP_FAILURES);
		if (err == -ESTALE)
			actiondfs_drop_node_blob_if_current(node, file);
	}
	fput(file);
	return err;
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

	return actiondfs_append_cached_file_child(parent,
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
	return actiondfs_append_cached_dir_child(parent,
						 dir.name, dir.name_len,
						 S_IFDIR | ACTIONDFS_DIR_MODE,
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

	file = actiondfs_open_directory_blob(sbi, hash);
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
	actiondfs_stat_inc(ACTIONDFS_STAT_DIRECTORY_BLOB_READS);
	actiondfs_stat_add(ACTIONDFS_STAT_DIRECTORY_BLOB_BYTES, (u64)size);
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

static void actiondfs_note_blob_path_cache_hit(
	struct actiondfs_blob_path_cache_entry *entry)
{
	atomic_add_unless(&entry->hits, 1, INT_MAX);
}

static struct actiondfs_blob_path_cache_entry *
actiondfs_find_blob_path_cache_locked(const char *hash)
{
	struct actiondfs_blob_path_cache_entry *entry;
	unsigned long key = actiondfs_digest_cache_key(hash);

	hash_for_each_possible(actiondfs_blob_path_cache, entry, hnode, key) {
		if (!memcmp(entry->hash, hash, 64))
			return entry;
	}
	return NULL;
}

static struct actiondfs_blob_path_cache_entry *
actiondfs_find_blob_path_cache_rcu(const char *hash)
{
	struct actiondfs_blob_path_cache_entry *entry;
	unsigned long key = actiondfs_digest_cache_key(hash);

	hash_for_each_possible_rcu(actiondfs_blob_path_cache, entry, hnode, key) {
		if (!memcmp(entry->hash, hash, 64))
			return entry;
	}
	return NULL;
}

static void actiondfs_get_blob_path_cache_entry_locked(
	struct actiondfs_blob_path_cache_entry *entry,
	struct path *out)
{
	actiondfs_note_blob_path_cache_hit(entry);
	list_move_tail(&entry->list, &actiondfs_blob_path_cache_list);
	path_get(&entry->path);
	*out = entry->path;
}

static void actiondfs_evict_blob_path_cache_one_locked(void)
{
	struct actiondfs_blob_path_cache_entry *entry;
	struct actiondfs_blob_path_cache_entry *victim = NULL;

	list_for_each_entry(entry, &actiondfs_blob_path_cache_list, list) {
		if (!victim ||
		    atomic_read(&entry->hits) < atomic_read(&victim->hits))
			victim = entry;
	}
	if (!victim)
		return;

	hash_del_rcu(&victim->hnode);
	list_del(&victim->list);
	actiondfs_blob_path_cache_count--;
	actiondfs_stat_inc(ACTIONDFS_STAT_BLOB_PATH_CACHE_EVICTIONS);
	synchronize_rcu();
	actiondfs_free_blob_path_cache_entry(victim);
}

static int actiondfs_insert_blob_path_cache(const char *hash,
					    const struct path *path,
					    struct path *out)
{
	struct actiondfs_blob_path_cache_entry *entry;
	struct actiondfs_blob_path_cache_entry *existing;
	unsigned long key;

	entry = kzalloc(sizeof(*entry), GFP_KERNEL);
	if (!entry) {
		path_get(path);
		*out = *path;
		return 0;
	}

	memcpy(entry->hash, hash, 64);
	entry->hash[64] = '\0';
	atomic_set(&entry->hits, 0);
	entry->path = *path;
	path_get(&entry->path);
	INIT_LIST_HEAD(&entry->list);

	mutex_lock(&actiondfs_blob_path_cache_lock);
	existing = actiondfs_find_blob_path_cache_locked(hash);
	if (existing) {
		actiondfs_get_blob_path_cache_entry_locked(existing, out);
		mutex_unlock(&actiondfs_blob_path_cache_lock);
		actiondfs_stat_inc(ACTIONDFS_STAT_BLOB_PATH_CACHE_RACES);
		actiondfs_free_blob_path_cache_entry(entry);
		return 0;
	}

	while (actiondfs_blob_path_cache_count >= ACTIONDFS_BLOB_PATH_CACHE_MAX)
		actiondfs_evict_blob_path_cache_one_locked();

	key = actiondfs_digest_cache_key(hash);
	hash_add_rcu(actiondfs_blob_path_cache, &entry->hnode, key);
	list_add_tail(&entry->list, &actiondfs_blob_path_cache_list);
	actiondfs_blob_path_cache_count++;
	actiondfs_stat_inc(ACTIONDFS_STAT_BLOB_PATH_CACHE_INSERTS);
	actiondfs_get_blob_path_cache_entry_locked(entry, out);
	mutex_unlock(&actiondfs_blob_path_cache_lock);
	return 0;
}

static int actiondfs_get_cached_blob_path(struct actiondfs_sb_info *sbi,
					  const char *hash,
					  struct path *out)
{
	struct actiondfs_blob_path_cache_entry *entry;
	char path[ACTIONDFS_SHARDED_HASH_PATH_LEN + 1];
	struct path real_path;
	int err;

	rcu_read_lock();
	entry = actiondfs_find_blob_path_cache_rcu(hash);
	if (entry) {
		actiondfs_note_blob_path_cache_hit(entry);
		path_get(&entry->path);
		*out = entry->path;
		rcu_read_unlock();
		actiondfs_stat_inc(ACTIONDFS_STAT_BLOB_PATH_CACHE_HITS);
		return 0;
	}
	rcu_read_unlock();

	mutex_lock(&actiondfs_blob_path_cache_lock);
	entry = actiondfs_find_blob_path_cache_locked(hash);
	if (entry) {
		actiondfs_get_blob_path_cache_entry_locked(entry, out);
		mutex_unlock(&actiondfs_blob_path_cache_lock);
		actiondfs_stat_inc(ACTIONDFS_STAT_BLOB_PATH_CACHE_HITS);
		return 0;
	}
	mutex_unlock(&actiondfs_blob_path_cache_lock);

	actiondfs_stat_inc(ACTIONDFS_STAT_BLOB_PATH_CACHE_MISSES);
	actiondfs_sharded_hash_path(hash, path);
	err = vfs_path_lookup(sbi->cas_path.dentry, sbi->cas_path.mnt,
			      path, LOOKUP_FOLLOW, &real_path);
	if (err)
		return err;

	err = actiondfs_insert_blob_path_cache(hash, &real_path, out);
	path_put(&real_path);
	return err;
}

static void actiondfs_drop_cached_blob_path(const char *hash)
{
	struct actiondfs_blob_path_cache_entry *entry;

	mutex_lock(&actiondfs_blob_path_cache_lock);
	entry = actiondfs_find_blob_path_cache_locked(hash);
	if (entry) {
		hash_del_rcu(&entry->hnode);
		list_del(&entry->list);
		actiondfs_blob_path_cache_count--;
	}
	mutex_unlock(&actiondfs_blob_path_cache_lock);
	if (entry) {
		synchronize_rcu();
		actiondfs_free_blob_path_cache_entry(entry);
	}
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
	actiondfs_stat_inc(ACTIONDFS_STAT_CACHED_DIR_BUILDS);
	actiondfs_stat_add(ACTIONDFS_STAT_CACHED_DIR_BYTES, (u64)len);

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

	actiondfs_stat_inc(ACTIONDFS_STAT_CACHED_DIR_REQUESTS);
	mutex_lock(&actiondfs_dir_cache_lock);
	entry = actiondfs_find_cached_dir_locked(hash);
	mutex_unlock(&actiondfs_dir_cache_lock);
	if (entry) {
		actiondfs_stat_inc(ACTIONDFS_STAT_DIR_CACHE_HITS);
		*out = entry;
		return 0;
	}

	actiondfs_stat_inc(ACTIONDFS_STAT_DIR_CACHE_MISSES);
	err = actiondfs_build_cached_dir(sbi, hash, &entry);
	if (err)
		return err;

	key = actiondfs_digest_cache_key(hash);
	mutex_lock(&actiondfs_dir_cache_lock);
	existing = actiondfs_find_cached_dir_locked(hash);
	if (existing) {
		mutex_unlock(&actiondfs_dir_cache_lock);
		actiondfs_free_cached_dir(entry);
		actiondfs_stat_inc(ACTIONDFS_STAT_DIR_CACHE_RACES);
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
	dir->cached_dir = cached;
	dir->loaded = true;
	return 0;
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

	if (dir->parent) {
		struct actiondfs_cached_dir *cached;

		err = actiondfs_get_cached_dir(sbi, dir->hash, &cached);
		if (err)
			return err;
		return actiondfs_attach_cached_dir(dir, cached);
	}

	if (!dir->parent)
		actiondfs_stat_inc(ACTIONDFS_STAT_ROOT_DIR_PARSES);
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
	if (!dir->loaded) {
		actiondfs_stat_inc(ACTIONDFS_STAT_DIR_LOADS);
		err = actiondfs_load_reapi_directory_locked(sbi, dir);
	}
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

	actiondfs_stat_inc(ACTIONDFS_STAT_LOOKUPS);
	child = actiondfs_lookup_child(actiondfs_sbi(dir->i_sb), parent,
				       dentry->d_name.name, dentry->d_name.len);
	if (IS_ERR(child))
		return ERR_CAST(child);
	if (child) {
		actiondfs_stat_inc(ACTIONDFS_STAT_LOOKUP_HITS);
		inode = actiondfs_iget(dir->i_sb, child);
		if (IS_ERR(inode))
			return ERR_CAST(inode);
	} else {
		actiondfs_stat_inc(ACTIONDFS_STAT_LOOKUP_NEGATIVE);
	}

	d_add(dentry, inode);
	return NULL;
}

static int actiondfs_iterate_shared(struct file *file, struct dir_context *ctx)
{
	struct inode *inode = file_inode(file);
	struct actiondfs_node *dir = inode->i_private;
	size_t i;
	loff_t base = 2;
	int err;

	err = actiondfs_ensure_loaded(inode->i_sb, dir);
	if (err)
		return err;

	actiondfs_stat_inc(ACTIONDFS_STAT_READDIRS);

	if (!dir_emit_dots(file, ctx))
		return 0;
	if (ctx->pos > 2)
		actiondfs_stat_inc(ACTIONDFS_STAT_READDIR_RESUMES);

	if (dir->cached_dir) {
		struct actiondfs_cached_dir *cached = dir->cached_dir;

		i = actiondfs_readdir_start_index_counted(ctx->pos, base,
							  cached->file_count);
		for (; i < cached->file_count; i++) {
			struct actiondfs_cached_child *child = &cached->file_children[i];
			loff_t pos = base + i;

			if (!dir_emit(ctx, child->name, child->name_len, 0, DT_REG))
				return 0;
			actiondfs_stat_inc(ACTIONDFS_STAT_READDIR_ENTRIES);
			ctx->pos = pos + 1;
		}
		base += cached->file_count;

		i = actiondfs_readdir_start_index_counted(ctx->pos, base,
							  cached->dir_count);
		for (; i < cached->dir_count; i++) {
			struct actiondfs_cached_child *child = &cached->dir_children[i];
			loff_t pos = base + i;

			if (!dir_emit(ctx, child->name, child->name_len, 0, DT_DIR))
				return 0;
			actiondfs_stat_inc(ACTIONDFS_STAT_READDIR_ENTRIES);
			ctx->pos = pos + 1;
		}
		return 0;
	}

	i = actiondfs_readdir_start_index_counted(ctx->pos, base,
						  dir->file_count);
	for (; i < dir->file_count; i++) {
		struct actiondfs_node *child = dir->file_children[i];
		loff_t pos = base + i;

		if (!dir_emit(ctx, child->name, child->name_len, child->ino, DT_REG))
			return 0;
		actiondfs_stat_inc(ACTIONDFS_STAT_READDIR_ENTRIES);
		ctx->pos = pos + 1;
	}
	base += dir->file_count;

	i = actiondfs_readdir_start_index_counted(ctx->pos, base,
						  dir->dir_count);
	for (; i < dir->dir_count; i++) {
		struct actiondfs_node *child = dir->dir_children[i];
		loff_t pos = base + i;

		if (!dir_emit(ctx, child->name, child->name_len, child->ino, DT_DIR))
			return 0;
		actiondfs_stat_inc(ACTIONDFS_STAT_READDIR_ENTRIES);
		ctx->pos = pos + 1;
	}
	return 0;
}

static size_t actiondfs_readdir_start_index(loff_t ctx_pos, loff_t base,
					    size_t count)
{
	loff_t delta;

	if (ctx_pos <= base)
		return 0;
	delta = ctx_pos - base;
	if (delta >= (loff_t)count)
		return count;
	return (size_t)delta;
}

static size_t actiondfs_readdir_start_index_counted(loff_t ctx_pos, loff_t base,
						    size_t count)
{
	size_t start = actiondfs_readdir_start_index(ctx_pos, base, count);

	if (start)
		actiondfs_stat_add(ACTIONDFS_STAT_READDIR_SKIPPED_ENTRIES_AVOIDED,
				   (u64)start);
	return start;
}

static const struct inode_operations actiondfs_file_iops = {
	.getattr = simple_getattr,
};

static const struct file_operations actiondfs_file_fops = {
	.llseek = generic_file_llseek,
	.read_iter = actiondfs_read_iter,
	.mmap = actiondfs_mmap,
	.splice_read = actiondfs_splice_read,
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

struct actiondfs_mount_context {
	char *options;
};

static int actiondfs_fill_super(struct super_block *sb, struct fs_context *fc)
{
	struct actiondfs_mount_context *ctx = fc->fs_private;
	struct actiondfs_sb_info *sbi;
	struct inode *root_inode;
	int err;

	sbi = kzalloc(sizeof(*sbi), GFP_KERNEL);
	if (!sbi)
		return -ENOMEM;

	sb->s_fs_info = sbi;
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

	err = actiondfs_parse_options(sbi, ctx ? ctx->options : NULL);
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
	actiondfs_stat_inc(ACTIONDFS_STAT_MOUNTS);
	return 0;

fail:
	actiondfs_put_super(sb);
	return err;
}

static int actiondfs_get_tree(struct fs_context *fc)
{
	fc->sb_flags |= SB_RDONLY;
	return get_tree_nodev(fc, actiondfs_fill_super);
}

static int actiondfs_parse_monolithic(struct fs_context *fc, void *data)
{
	struct actiondfs_mount_context *ctx = fc->fs_private;
	char *options;

	if (!ctx || !data)
		return -EINVAL;

	options = kstrdup(data, GFP_KERNEL);
	if (!options)
		return -ENOMEM;

	kfree(ctx->options);
	ctx->options = options;
	return 0;
}

static void actiondfs_free_context(struct fs_context *fc)
{
	struct actiondfs_mount_context *ctx = fc->fs_private;

	if (!ctx)
		return;
	kfree(ctx->options);
	kfree(ctx);
}

static const struct fs_context_operations actiondfs_context_ops = {
	.free = actiondfs_free_context,
	.parse_monolithic = actiondfs_parse_monolithic,
	.get_tree = actiondfs_get_tree,
};

static int actiondfs_init_fs_context(struct fs_context *fc)
{
	struct actiondfs_mount_context *ctx;

	ctx = kzalloc(sizeof(*ctx), GFP_KERNEL);
	if (!ctx)
		return -ENOMEM;

	fc->fs_private = ctx;
	fc->ops = &actiondfs_context_ops;
	return 0;
}

static struct file_system_type actiondfs_fs_type = {
	.owner = THIS_MODULE,
	.name = "actiondfs",
	.init_fs_context = actiondfs_init_fs_context,
	.kill_sb = kill_anon_super,
};

static struct file_system_type *actiondfs_fs_types[] = {
	&actiondfs_fs_type,
};

static int actiondfs_stats_show(struct seq_file *m, void *v)
{
	size_t i;

	for (i = 0; i < ACTIONDFS_STAT_COUNT; i++)
		seq_printf(m, "%s %lld\n", actiondfs_stat_names[i],
			   atomic64_read(&actiondfs_stats[i]));
	return 0;
}

static int __init actiondfs_init(void)
{
	size_t i;
	int err;

	for (i = 0; i < ARRAY_SIZE(actiondfs_fs_types); i++) {
		err = register_filesystem(actiondfs_fs_types[i]);
		if (err)
			goto fail;
	}
	if (!proc_create_single(ACTIONDFS_PROC_STATS, 0444, NULL,
				actiondfs_stats_show)) {
		err = -ENOMEM;
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

	remove_proc_entry(ACTIONDFS_PROC_STATS, NULL);
	for (i = ARRAY_SIZE(actiondfs_fs_types); i > 0; i--)
		unregister_filesystem(actiondfs_fs_types[i - 1]);
	actiondfs_destroy_blob_path_cache();
	actiondfs_destroy_dir_cache();
}

module_init(actiondfs_init);
module_exit(actiondfs_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("actiond manifest filesystem");
