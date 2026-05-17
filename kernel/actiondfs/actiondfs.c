// SPDX-License-Identifier: GPL-2.0-only
/*
 * actiondfs - read-only action input manifest filesystem for actiond.
 *
 * Mount data:
 *   manifest=/path/to/manifest,cas=/cas/blobs/sha256
 *
 * Manifest format:
 *   actiondfs.v1
 *   d MODE PATH_HEX
 *   f MODE SIZE HASH_HEX PATH_HEX
 */

#include <linux/cred.h>
#include <linux/err.h>
#include <linux/fs.h>
#include <linux/highmem.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/magic.h>
#include <linux/module.h>
#include <linux/mount.h>
#include <linux/namei.h>
#include <linux/pagemap.h>
#include <linux/parser.h>
#include <linux/slab.h>
#include <linux/statfs.h>
#include <linux/string.h>
#include <linux/uaccess.h>
#include <linux/vmalloc.h>

#define ACTIONDFS_MAGIC 0x41444653
#define ACTIONDFS_VERSION "actiondfs.v1"
#define ACTIONDFS_MAX_MANIFEST_SIZE (64U * 1024U * 1024U)

struct actiondfs_node {
	char *name;
	u64 ino;
	umode_t mode;
	u64 size;
	char hash[65];
	struct actiondfs_node *parent;
	struct actiondfs_node *children;
	struct actiondfs_node *next;
};

struct actiondfs_sb_info {
	char *manifest_path;
	char *cas_root;
	struct actiondfs_node *root;
	u64 next_ino;
};

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
	struct actiondfs_node *child;
	struct actiondfs_node *next;

	if (!node)
		return;

	child = node->children;
	while (child) {
		next = child->next;
		actiondfs_free_tree(child);
		child = next;
	}

	kfree(node->name);
	kfree(node);
}

static struct actiondfs_node *actiondfs_alloc_node(struct actiondfs_sb_info *sbi,
						   const char *name,
						   umode_t mode)
{
	struct actiondfs_node *node;

	node = kzalloc(sizeof(*node), GFP_KERNEL);
	if (!node)
		return NULL;

	node->name = kstrdup(name, GFP_KERNEL);
	if (!node->name) {
		kfree(node);
		return NULL;
	}

	node->ino = ++sbi->next_ino;
	node->mode = mode;
	return node;
}

static struct actiondfs_node *actiondfs_find_child(struct actiondfs_node *dir,
						   const char *name,
						   size_t len)
{
	struct actiondfs_node *child;

	for (child = dir->children; child; child = child->next) {
		if (strlen(child->name) == len && !memcmp(child->name, name, len))
			return child;
	}
	return NULL;
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

static int actiondfs_add_child(struct actiondfs_node *dir,
			       struct actiondfs_node *child)
{
	struct actiondfs_node **slot;

	if (!actiondfs_is_dir(dir))
		return -ENOTDIR;
	if (actiondfs_find_child(dir, child->name, strlen(child->name)))
		return -EEXIST;

	child->parent = dir;
	slot = &dir->children;
	while (*slot)
		slot = &(*slot)->next;
	*slot = child;
	return 0;
}

static struct actiondfs_node *actiondfs_ensure_dir(struct actiondfs_sb_info *sbi,
						   const char *path)
{
	struct actiondfs_node *dir = sbi->root;
	const char *cursor = path;
	int err;

	if (!path || !*path)
		return dir;

	while (*cursor) {
		const char *slash = strchrnul(cursor, '/');
		size_t len = slash - cursor;
		struct actiondfs_node *child;
		char *name;

		err = actiondfs_valid_component(cursor, len);
		if (err)
			return ERR_PTR(err);

		child = actiondfs_find_child(dir, cursor, len);
		if (child) {
			if (!actiondfs_is_dir(child))
				return ERR_PTR(-ENOTDIR);
			dir = child;
		} else {
			name = kmemdup_nul(cursor, len, GFP_KERNEL);
			if (!name)
				return ERR_PTR(-ENOMEM);
			child = actiondfs_alloc_node(sbi, name, S_IFDIR | 0555);
			kfree(name);
			if (!child)
				return ERR_PTR(-ENOMEM);
			err = actiondfs_add_child(dir, child);
			if (err) {
				actiondfs_free_tree(child);
				return ERR_PTR(err);
			}
			dir = child;
		}

		cursor = *slash ? slash + 1 : slash;
	}

	return dir;
}

static int actiondfs_add_file(struct actiondfs_sb_info *sbi,
			      const char *path,
			      umode_t mode,
			      u64 size,
			      const char *hash)
{
	char *parent_path = NULL;
	const char *name;
	const char *slash;
	struct actiondfs_node *parent;
	struct actiondfs_node *file;
	int err;

	slash = strrchr(path, '/');
	if (slash) {
		parent_path = kmemdup_nul(path, slash - path, GFP_KERNEL);
		if (!parent_path)
			return -ENOMEM;
		parent = actiondfs_ensure_dir(sbi, parent_path);
		kfree(parent_path);
		name = slash + 1;
	} else {
		parent = sbi->root;
		name = path;
	}

	if (IS_ERR(parent))
		return PTR_ERR(parent);

	err = actiondfs_valid_component(name, strlen(name));
	if (err)
		return err;
	if (actiondfs_find_child(parent, name, strlen(name)))
		return -EEXIST;

	file = actiondfs_alloc_node(sbi, name, S_IFREG | (mode & 0777));
	if (!file)
		return -ENOMEM;

	file->size = size;
	memcpy(file->hash, hash, 64);
	file->hash[64] = '\0';

	err = actiondfs_add_child(parent, file);
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

static char *actiondfs_hex_decode(const char *hex)
{
	size_t hex_len = strlen(hex);
	size_t out_len = hex_len / 2;
	char *out;
	size_t i;

	if ((hex_len & 1) != 0)
		return ERR_PTR(-EINVAL);

	out = kmalloc(out_len + 1, GFP_KERNEL);
	if (!out)
		return ERR_PTR(-ENOMEM);

	for (i = 0; i < out_len; i++) {
		int high = actiondfs_hex_nibble(hex[i * 2]);
		int low = actiondfs_hex_nibble(hex[i * 2 + 1]);
		if (high < 0 || low < 0) {
			kfree(out);
			return ERR_PTR(-EINVAL);
		}
		out[i] = (high << 4) | low;
	}
	out[out_len] = '\0';

	if (strlen(out) != out_len) {
		kfree(out);
		return ERR_PTR(-EINVAL);
	}
	return out;
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

static int actiondfs_parse_mode(const char *text, umode_t *mode)
{
	unsigned int value;
	int err;

	err = kstrtouint(text, 8, &value);
	if (err)
		return err;
	if (value & ~0777U)
		return -EINVAL;
	*mode = value;
	return 0;
}

static int actiondfs_parse_line(struct actiondfs_sb_info *sbi, char *line)
{
	char *type;
	char *mode_text;
	char *size_text;
	char *hash;
	char *path_hex;
	char *path;
	umode_t mode;
	u64 size;
	int err;

	if (!*line)
		return 0;

	type = strsep(&line, " ");
	mode_text = strsep(&line, " ");
	if (!type || !mode_text)
		return -EINVAL;

	err = actiondfs_parse_mode(mode_text, &mode);
	if (err)
		return err;

	if (!strcmp(type, "d")) {
		path_hex = strsep(&line, " ");
		if (!path_hex || (line && *line))
			return -EINVAL;
		path = actiondfs_hex_decode(path_hex);
		if (IS_ERR(path))
			return PTR_ERR(path);
		err = PTR_ERR_OR_ZERO(actiondfs_ensure_dir(sbi, path));
		kfree(path);
		return err;
	}

	if (strcmp(type, "f"))
		return -EINVAL;

	size_text = strsep(&line, " ");
	hash = strsep(&line, " ");
	path_hex = strsep(&line, " ");
	if (!size_text || !hash || !path_hex || (line && *line))
		return -EINVAL;

	err = kstrtou64(size_text, 10, &size);
	if (err)
		return err;
	err = actiondfs_valid_hash(hash);
	if (err)
		return err;
	path = actiondfs_hex_decode(path_hex);
	if (IS_ERR(path))
		return PTR_ERR(path);
	err = actiondfs_add_file(sbi, path, mode, size, hash);
	kfree(path);
	return err;
}

static int actiondfs_load_manifest(struct actiondfs_sb_info *sbi)
{
	struct file *file;
	loff_t pos = 0;
	loff_t size;
	ssize_t nread;
	char *buffer;
	char *cursor;
	char *line;
	int err = 0;

	file = filp_open(sbi->manifest_path, O_RDONLY, 0);
	if (IS_ERR(file))
		return PTR_ERR(file);

	size = i_size_read(file_inode(file));
	if (size <= 0 || size > ACTIONDFS_MAX_MANIFEST_SIZE) {
		filp_close(file, NULL);
		return -EINVAL;
	}

	buffer = kvzalloc(size + 1, GFP_KERNEL);
	if (!buffer) {
		filp_close(file, NULL);
		return -ENOMEM;
	}

	nread = kernel_read(file, buffer, size, &pos);
	filp_close(file, NULL);
	if (nread < 0) {
		kvfree(buffer);
		return nread;
	}
	if (nread != size) {
		kvfree(buffer);
		return -EIO;
	}
	buffer[size] = '\0';

	cursor = buffer;
	line = strsep(&cursor, "\n");
	if (!line || strcmp(line, ACTIONDFS_VERSION)) {
		kvfree(buffer);
		return -EINVAL;
	}

	while ((line = strsep(&cursor, "\n")) != NULL) {
		err = actiondfs_parse_line(sbi, line);
		if (err)
			break;
	}

	kvfree(buffer);
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
		if (str_has_prefix(token, "manifest=")) {
			kfree(sbi->manifest_path);
			sbi->manifest_path = kstrdup(token + 9, GFP_KERNEL);
			if (!sbi->manifest_path) {
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
	if (!sbi->manifest_path || !sbi->cas_root)
		return -EINVAL;
	if (strchr(sbi->manifest_path, ',') || strchr(sbi->cas_root, ','))
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

	if (dentry->d_name.len > NAME_MAX)
		return ERR_PTR(-ENAMETOOLONG);

	child = actiondfs_find_child(parent, dentry->d_name.name, dentry->d_name.len);
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
	struct actiondfs_node *child;
	loff_t pos = 2;

	if (!dir_emit_dots(file, ctx))
		return 0;

	for (child = dir->children; child; child = child->next, pos++) {
		unsigned int type = actiondfs_is_dir(child) ? DT_DIR : DT_REG;

		if (pos < ctx->pos)
			continue;
		if (!dir_emit(ctx, child->name, strlen(child->name), child->ino, type))
			return 0;
		ctx->pos = pos + 1;
	}
	return 0;
}

static char *actiondfs_blob_path(struct actiondfs_sb_info *sbi,
				 struct actiondfs_node *node)
{
	return kasprintf(GFP_KERNEL, "%s/%s", sbi->cas_root, node->hash);
}

static int actiondfs_read_folio(struct file *file, struct folio *folio)
{
	struct inode *inode = file_inode(file);
	struct actiondfs_node *node = inode->i_private;
	struct actiondfs_sb_info *sbi = actiondfs_sbi(inode->i_sb);
	struct file *blob = NULL;
	char *blob_path = NULL;
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
		loff_t pos = offset;

		blob_path = actiondfs_blob_path(sbi, node);
		if (!blob_path) {
			err = -ENOMEM;
			goto out;
		}

		blob = filp_open(blob_path, O_RDONLY, 0);
		if (IS_ERR(blob)) {
			err = PTR_ERR(blob);
			blob = NULL;
			goto out;
		}

		nread = kernel_read(blob, addr, wanted, &pos);
		if (nread < 0) {
			err = nread;
			goto out;
		}
		if (nread != wanted) {
			err = -EIO;
			goto out;
		}
	}

	folio_mark_uptodate(folio);

out:
	kunmap_local(addr);
	if (blob)
		filp_close(blob, NULL);
	kfree(blob_path);
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
	kfree(sbi->manifest_path);
	kfree(sbi->cas_root);
	kfree(sbi);
	sb->s_fs_info = NULL;
}

static const struct super_operations actiondfs_super_ops = {
	.statfs = simple_statfs,
	.put_super = actiondfs_put_super,
};

static int actiondfs_fill_super(struct super_block *sb, void *data, int silent)
{
	struct actiondfs_sb_info *sbi;
	struct inode *root_inode;
	int err;

	sbi = kzalloc(sizeof(*sbi), GFP_KERNEL);
	if (!sbi)
		return -ENOMEM;

	sb->s_fs_info = sbi;
	sb->s_magic = ACTIONDFS_MAGIC;
	sb->s_maxbytes = MAX_LFS_FILESIZE;
	sb->s_blocksize = PAGE_SIZE;
	sb->s_blocksize_bits = PAGE_SHIFT;
	sb->s_flags |= SB_RDONLY | SB_NOATIME;
	sb->s_op = &actiondfs_super_ops;
	sb->s_time_gran = 1;

	sbi->root = actiondfs_alloc_node(sbi, "", S_IFDIR | 0555);
	if (!sbi->root) {
		err = -ENOMEM;
		goto fail;
	}

	err = actiondfs_parse_options(sbi, data);
	if (err)
		goto fail;
	err = actiondfs_load_manifest(sbi);
	if (err)
		goto fail;

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

static struct dentry *actiondfs_mount(struct file_system_type *fs_type,
				      int flags,
				      const char *dev_name,
				      void *data)
{
	return mount_nodev(fs_type, flags | SB_RDONLY, data, actiondfs_fill_super);
}

static struct file_system_type actiondfs_fs_type = {
	.owner = THIS_MODULE,
	.name = "actiondfs",
	.mount = actiondfs_mount,
	.kill_sb = kill_anon_super,
};

static int __init actiondfs_init(void)
{
	return register_filesystem(&actiondfs_fs_type);
}

static void __exit actiondfs_exit(void)
{
	unregister_filesystem(&actiondfs_fs_type);
}

module_init(actiondfs_init);
module_exit(actiondfs_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("actiond manifest filesystem");
