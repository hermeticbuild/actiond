// SPDX-License-Identifier: GPL-2.0-only
/*
 * actiondfs - action input and staged output filesystem for actiond.
 *
 * Mount data:
 *   root=<input-root-directory-digest-hash>,root_size=<bytes>,cas=/cas/blobs/sha256[,stage=/stage]
 *
 * Directory/FileNode metadata is read lazily from REAPI Directory protos stored
 * in the CAS. File contents are read by digest from the same CAS blob root.
 */

#include <linux/backing-file.h>
#include <linux/atomic.h>
#include <linux/cred.h>
#include <linux/delay.h>
#include <linux/delayed_call.h>
#include <linux/err.h>
#include <linux/file.h>
#include <linux/fs.h>
#include <linux/fs_context.h>
#include <linux/hashtable.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/ktime.h>
#include <linux/list.h>
#include <linux/magic.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/mount.h>
#include <linux/mutex.h>
#include <linux/namei.h>
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
#include <linux/workqueue.h>

#ifndef ACTIONDFS_ENABLE_STATS
#define ACTIONDFS_ENABLE_STATS 0
#endif

#ifndef ACTIONDFS_FS_NAME
#define ACTIONDFS_FS_NAME "actiondfs"
#endif

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
#define ACTIONDFS_MAX_STAGE_DEPTH ((PATH_MAX + 1) / 2)
#define ACTIONDFS_EMPTY_SHA256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
#define ACTIONDFS_UNKNOWN_SIZE (~(u64)0)

struct actiondfs_cached_child {
	char *name;
	size_t name_len;
	char *link_target;
	umode_t mode;
	u64 size;
	char hash[65];
};

struct actiondfs_cached_dir {
	struct hlist_node hnode;
	struct dentry *cas_root;
	char hash[65];
	u64 size;
	struct actiondfs_cached_child *file_children;
	size_t file_count;
	size_t file_capacity;
	struct actiondfs_cached_child *dir_children;
	size_t dir_count;
	size_t dir_capacity;
	struct actiondfs_cached_child *symlink_children;
	size_t symlink_count;
	size_t symlink_capacity;
};

struct actiondfs_blob_path_cache_entry {
	struct hlist_node hnode;
	struct list_head list;
	struct rcu_head rcu;
	struct work_struct release_work;
	char hash[65];
	struct dentry *cas_root;
	struct dentry *dentry;
};

enum actiondfs_node_origin {
	ACTIONDFS_NODE_INPUT,
	ACTIONDFS_NODE_STAGED,
};

struct actiondfs_node {
	enum actiondfs_node_origin origin;
	u64 ino;
	umode_t mode;
	u64 size;
	char *link_target;
	char hash[65];
	const char *input_name;
	size_t input_name_len;
	struct mutex load_lock;
	bool loaded;
	struct actiondfs_node *parent;
	struct dentry *stage_dentry;
	bool stage_parent_ready;
	struct actiondfs_cached_dir *cached_dir;
	atomic64_t stage_generation;
};

struct actiondfs_sb_info {
	struct path cas_path;
	struct path stage_path;
	bool stage_path_valid;
	struct actiondfs_node *root;
};

struct actiondfs_mount_options {
	char *cas_root;
	char *root_hash;
	u64 root_size;
	char *stage_root;
};

#if ACTIONDFS_ENABLE_STATS
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
	ACTIONDFS_STAT_LOOKUPS,
	ACTIONDFS_STAT_LOOKUP_HITS,
	ACTIONDFS_STAT_LOOKUP_NEGATIVE,
	ACTIONDFS_STAT_READDIRS,
	ACTIONDFS_STAT_READDIR_ENTRIES,
	ACTIONDFS_STAT_READDIR_RESUMES,
	ACTIONDFS_STAT_READDIR_SKIPPED_ENTRIES_AVOIDED,
	ACTIONDFS_STAT_BLOB_OPEN_ATTEMPTS,
	ACTIONDFS_STAT_BLOB_OPEN_STALE_RETRIES,
	ACTIONDFS_STAT_BLOB_OPEN_BACKING_TOTAL_NS,
	ACTIONDFS_STAT_BLOB_OPEN_BACKING_PATH_NS,
	ACTIONDFS_STAT_BLOB_OPEN_BACKING_FILE_NS,
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
	ACTIONDFS_STAT_STAGE_CHILD_LOOKUPS,
	ACTIONDFS_STAT_STAGE_CHILD_LOOKUP_HITS,
	ACTIONDFS_STAT_STAGE_CHILD_LOOKUP_NEGATIVE,
	ACTIONDFS_STAT_STAGE_CHILD_LOOKUP_ERRORS,
	ACTIONDFS_STAT_STAGE_ENSURE_DIR_CALLS,
	ACTIONDFS_STAT_STAGE_ENSURE_DIR_COMPONENTS,
	ACTIONDFS_STAT_STAGE_ENSURE_DIR_EXISTING,
	ACTIONDFS_STAT_STAGE_ENSURE_DIR_CREATED,
	ACTIONDFS_STAT_STAGE_ENSURE_DIR_ERRORS,
	ACTIONDFS_STAT_STAGE_PARENT_DENTRY_HITS,
	ACTIONDFS_STAT_STAGE_INODE_LOOKUPS,
	ACTIONDFS_STAT_STAGE_INODE_LOOKUP_UNSTAGED_PARENT,
	ACTIONDFS_STAT_STAGE_INODE_LOOKUP_HITS,
	ACTIONDFS_STAT_STAGE_INODE_LOOKUP_NEGATIVE,
	ACTIONDFS_STAT_STAGE_INODE_LOOKUP_ERRORS,
	ACTIONDFS_STAT_STAGE_INODE_LOOKUP_INPUT_DIR_MERGES,
	ACTIONDFS_STAT_STAGE_BACKING_OPEN_ATTEMPTS,
	ACTIONDFS_STAT_STAGE_BACKING_OPEN_FAILURES,
	ACTIONDFS_STAT_STAGE_BACKING_OPEN_TOTAL_NS,
	ACTIONDFS_STAT_STAGE_BACKING_OPEN_LOOKUP_NS,
	ACTIONDFS_STAT_STAGE_BACKING_OPEN_FILE_NS,
	ACTIONDFS_STAT_STAGE_READ_CALLS,
	ACTIONDFS_STAT_STAGE_READ_BYTES,
	ACTIONDFS_STAT_STAGE_READ_TOTAL_NS,
	ACTIONDFS_STAT_STAGE_WRITE_CALLS,
	ACTIONDFS_STAT_STAGE_WRITE_BYTES,
	ACTIONDFS_STAT_STAGE_WRITE_TOTAL_NS,
	ACTIONDFS_STAT_STAGE_SPLICE_READ_CALLS,
	ACTIONDFS_STAT_STAGE_SPLICE_READ_BYTES,
	ACTIONDFS_STAT_STAGE_SPLICE_READ_TOTAL_NS,
	ACTIONDFS_STAT_STAGE_MMAP_CALLS,
	ACTIONDFS_STAT_STAGE_MMAP_BYTES,
	ACTIONDFS_STAT_STAGE_MMAP_FAILURES,
	ACTIONDFS_STAT_STAGE_MMAP_TOTAL_NS,
	ACTIONDFS_STAT_STAGE_CREATE_CALLS,
	ACTIONDFS_STAT_STAGE_CREATE_SUCCESS,
	ACTIONDFS_STAT_STAGE_CREATE_FAILURES,
	ACTIONDFS_STAT_STAGE_MKDIR_CALLS,
	ACTIONDFS_STAT_STAGE_MKDIR_SUCCESS,
	ACTIONDFS_STAT_STAGE_MKDIR_FAILURES,
	ACTIONDFS_STAT_STAGE_UNLINK_CALLS,
	ACTIONDFS_STAT_STAGE_UNLINK_SUCCESS,
	ACTIONDFS_STAT_STAGE_UNLINK_FAILURES,
	ACTIONDFS_STAT_STAGE_RMDIR_CALLS,
	ACTIONDFS_STAT_STAGE_RMDIR_SUCCESS,
	ACTIONDFS_STAT_STAGE_RMDIR_FAILURES,
	ACTIONDFS_STAT_STAGE_RENAME_CALLS,
	ACTIONDFS_STAT_STAGE_RENAME_SUCCESS,
	ACTIONDFS_STAT_STAGE_RENAME_FAILURES,
	ACTIONDFS_STAT_STAGE_SETATTR_SIZE_CALLS,
	ACTIONDFS_STAT_STAGE_SETATTR_SIZE_SUCCESS,
	ACTIONDFS_STAT_STAGE_SETATTR_SIZE_FAILURES,
	ACTIONDFS_STAT_STAGE_READDIR_CALLS,
	ACTIONDFS_STAT_STAGE_READDIR_HITS,
	ACTIONDFS_STAT_STAGE_READDIR_MISSES,
	ACTIONDFS_STAT_STAGE_READDIR_ERRORS,
	ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_ATTEMPTS,
	ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_SUCCESS,
	ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_BYTES,
	ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_FALLBACKS,
	ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_TOTAL_NS,
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
	[ACTIONDFS_STAT_LOOKUPS] = "lookups",
	[ACTIONDFS_STAT_LOOKUP_HITS] = "lookup_hits",
	[ACTIONDFS_STAT_LOOKUP_NEGATIVE] = "lookup_negative",
	[ACTIONDFS_STAT_READDIRS] = "readdirs",
	[ACTIONDFS_STAT_READDIR_ENTRIES] = "readdir_entries",
	[ACTIONDFS_STAT_READDIR_RESUMES] = "readdir_resumes",
	[ACTIONDFS_STAT_READDIR_SKIPPED_ENTRIES_AVOIDED] = "readdir_skipped_entries_avoided",
	[ACTIONDFS_STAT_BLOB_OPEN_ATTEMPTS] = "blob_open_attempts",
	[ACTIONDFS_STAT_BLOB_OPEN_STALE_RETRIES] = "blob_open_stale_retries",
	[ACTIONDFS_STAT_BLOB_OPEN_BACKING_TOTAL_NS] = "blob_open_backing_total_ns",
	[ACTIONDFS_STAT_BLOB_OPEN_BACKING_PATH_NS] = "blob_open_backing_path_ns",
	[ACTIONDFS_STAT_BLOB_OPEN_BACKING_FILE_NS] = "blob_open_backing_file_ns",
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
	[ACTIONDFS_STAT_STAGE_CHILD_LOOKUPS] = "stage_child_lookups",
	[ACTIONDFS_STAT_STAGE_CHILD_LOOKUP_HITS] = "stage_child_lookup_hits",
	[ACTIONDFS_STAT_STAGE_CHILD_LOOKUP_NEGATIVE] = "stage_child_lookup_negative",
	[ACTIONDFS_STAT_STAGE_CHILD_LOOKUP_ERRORS] = "stage_child_lookup_errors",
	[ACTIONDFS_STAT_STAGE_ENSURE_DIR_CALLS] = "stage_ensure_dir_calls",
	[ACTIONDFS_STAT_STAGE_ENSURE_DIR_COMPONENTS] = "stage_ensure_dir_components",
	[ACTIONDFS_STAT_STAGE_ENSURE_DIR_EXISTING] = "stage_ensure_dir_existing",
	[ACTIONDFS_STAT_STAGE_ENSURE_DIR_CREATED] = "stage_ensure_dir_created",
	[ACTIONDFS_STAT_STAGE_ENSURE_DIR_ERRORS] = "stage_ensure_dir_errors",
	[ACTIONDFS_STAT_STAGE_PARENT_DENTRY_HITS] = "stage_parent_dentry_hits",
	[ACTIONDFS_STAT_STAGE_INODE_LOOKUPS] = "stage_inode_lookups",
	[ACTIONDFS_STAT_STAGE_INODE_LOOKUP_UNSTAGED_PARENT] = "stage_inode_lookup_unstaged_parent",
	[ACTIONDFS_STAT_STAGE_INODE_LOOKUP_HITS] = "stage_inode_lookup_hits",
	[ACTIONDFS_STAT_STAGE_INODE_LOOKUP_NEGATIVE] = "stage_inode_lookup_negative",
	[ACTIONDFS_STAT_STAGE_INODE_LOOKUP_ERRORS] = "stage_inode_lookup_errors",
	[ACTIONDFS_STAT_STAGE_INODE_LOOKUP_INPUT_DIR_MERGES] = "stage_inode_lookup_input_dir_merges",
	[ACTIONDFS_STAT_STAGE_BACKING_OPEN_ATTEMPTS] = "stage_backing_open_attempts",
	[ACTIONDFS_STAT_STAGE_BACKING_OPEN_FAILURES] = "stage_backing_open_failures",
	[ACTIONDFS_STAT_STAGE_BACKING_OPEN_TOTAL_NS] = "stage_backing_open_total_ns",
	[ACTIONDFS_STAT_STAGE_BACKING_OPEN_LOOKUP_NS] = "stage_backing_open_lookup_ns",
	[ACTIONDFS_STAT_STAGE_BACKING_OPEN_FILE_NS] = "stage_backing_open_file_ns",
	[ACTIONDFS_STAT_STAGE_READ_CALLS] = "stage_read_calls",
	[ACTIONDFS_STAT_STAGE_READ_BYTES] = "stage_read_bytes",
	[ACTIONDFS_STAT_STAGE_READ_TOTAL_NS] = "stage_read_total_ns",
	[ACTIONDFS_STAT_STAGE_WRITE_CALLS] = "stage_write_calls",
	[ACTIONDFS_STAT_STAGE_WRITE_BYTES] = "stage_write_bytes",
	[ACTIONDFS_STAT_STAGE_WRITE_TOTAL_NS] = "stage_write_total_ns",
	[ACTIONDFS_STAT_STAGE_SPLICE_READ_CALLS] = "stage_splice_read_calls",
	[ACTIONDFS_STAT_STAGE_SPLICE_READ_BYTES] = "stage_splice_read_bytes",
	[ACTIONDFS_STAT_STAGE_SPLICE_READ_TOTAL_NS] = "stage_splice_read_total_ns",
	[ACTIONDFS_STAT_STAGE_MMAP_CALLS] = "stage_mmap_calls",
	[ACTIONDFS_STAT_STAGE_MMAP_BYTES] = "stage_mmap_bytes",
	[ACTIONDFS_STAT_STAGE_MMAP_FAILURES] = "stage_mmap_failures",
	[ACTIONDFS_STAT_STAGE_MMAP_TOTAL_NS] = "stage_mmap_total_ns",
	[ACTIONDFS_STAT_STAGE_CREATE_CALLS] = "stage_create_calls",
	[ACTIONDFS_STAT_STAGE_CREATE_SUCCESS] = "stage_create_success",
	[ACTIONDFS_STAT_STAGE_CREATE_FAILURES] = "stage_create_failures",
	[ACTIONDFS_STAT_STAGE_MKDIR_CALLS] = "stage_mkdir_calls",
	[ACTIONDFS_STAT_STAGE_MKDIR_SUCCESS] = "stage_mkdir_success",
	[ACTIONDFS_STAT_STAGE_MKDIR_FAILURES] = "stage_mkdir_failures",
	[ACTIONDFS_STAT_STAGE_UNLINK_CALLS] = "stage_unlink_calls",
	[ACTIONDFS_STAT_STAGE_UNLINK_SUCCESS] = "stage_unlink_success",
	[ACTIONDFS_STAT_STAGE_UNLINK_FAILURES] = "stage_unlink_failures",
	[ACTIONDFS_STAT_STAGE_RMDIR_CALLS] = "stage_rmdir_calls",
	[ACTIONDFS_STAT_STAGE_RMDIR_SUCCESS] = "stage_rmdir_success",
	[ACTIONDFS_STAT_STAGE_RMDIR_FAILURES] = "stage_rmdir_failures",
	[ACTIONDFS_STAT_STAGE_RENAME_CALLS] = "stage_rename_calls",
	[ACTIONDFS_STAT_STAGE_RENAME_SUCCESS] = "stage_rename_success",
	[ACTIONDFS_STAT_STAGE_RENAME_FAILURES] = "stage_rename_failures",
	[ACTIONDFS_STAT_STAGE_SETATTR_SIZE_CALLS] = "stage_setattr_size_calls",
	[ACTIONDFS_STAT_STAGE_SETATTR_SIZE_SUCCESS] = "stage_setattr_size_success",
	[ACTIONDFS_STAT_STAGE_SETATTR_SIZE_FAILURES] = "stage_setattr_size_failures",
	[ACTIONDFS_STAT_STAGE_READDIR_CALLS] = "stage_readdir_calls",
	[ACTIONDFS_STAT_STAGE_READDIR_HITS] = "stage_readdir_hits",
	[ACTIONDFS_STAT_STAGE_READDIR_MISSES] = "stage_readdir_misses",
	[ACTIONDFS_STAT_STAGE_READDIR_ERRORS] = "stage_readdir_errors",
	[ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_ATTEMPTS] = "stage_copy_file_range_attempts",
	[ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_SUCCESS] = "stage_copy_file_range_success",
	[ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_BYTES] = "stage_copy_file_range_bytes",
	[ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_FALLBACKS] = "stage_copy_file_range_fallbacks",
	[ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_TOTAL_NS] = "stage_copy_file_range_total_ns",
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

static u64 actiondfs_stat_time_start(void)
{
	return ktime_get_ns();
}

static void actiondfs_stat_add_elapsed(enum actiondfs_stat stat, u64 start)
{
	actiondfs_stat_add(stat, ktime_get_ns() - start);
}
#else
#define actiondfs_stat_inc(stat) do { } while (0)
#define actiondfs_stat_add(stat, value) \
	do { (void)(value); } while (0)
#define actiondfs_stat_time_start() 0ULL
#define actiondfs_stat_add_elapsed(stat, start) \
	do { (void)(start); } while (0)
#endif

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
static struct workqueue_struct *actiondfs_blob_path_cache_release_wq;

static const struct inode_operations actiondfs_dir_iops;
static const struct inode_operations actiondfs_file_iops;
static const struct inode_operations actiondfs_symlink_iops;
static const struct file_operations actiondfs_dir_fops;
static const struct file_operations actiondfs_file_fops;
static void actiondfs_evict_inode(struct inode *inode);
static size_t actiondfs_readdir_start_index(loff_t ctx_pos, loff_t base,
					    size_t count);
static size_t actiondfs_readdir_start_index_counted(loff_t ctx_pos,
						    loff_t base, size_t count);
static int actiondfs_get_cached_blob_path(struct actiondfs_sb_info *sbi,
					  const char *hash,
					  struct path *out);
static void actiondfs_drop_cached_blob_path(struct actiondfs_sb_info *sbi,
					   const char *hash);

static struct actiondfs_sb_info *actiondfs_sbi(struct super_block *sb)
{
	return sb->s_fs_info;
}

static void actiondfs_free_cached_dir(struct actiondfs_cached_dir *dir);

static bool actiondfs_is_dir(const struct actiondfs_node *node)
{
	return S_ISDIR(node->mode);
}

static void actiondfs_free_node(struct actiondfs_node *node)
{
	if (!node)
		return;
	if (node->stage_dentry)
		dput(node->stage_dentry);
	kfree(node->link_target);
	kfree(node);
}

static struct actiondfs_node *actiondfs_alloc_node(umode_t mode)
{
	struct actiondfs_node *node;

	node = kzalloc(sizeof(*node), GFP_KERNEL);
	if (!node)
		return NULL;

	node->origin = ACTIONDFS_NODE_INPUT;
	node->mode = mode;
	node->loaded = true;
	mutex_init(&node->load_lock);
	atomic64_set(&node->stage_generation, 0);
	node->stage_parent_ready = false;
	return node;
}

static u64 actiondfs_input_child_ino(struct actiondfs_node *parent,
				     const char *name, size_t name_len,
				     bool is_dir)
{
	u64 hash = 1469598103934665603ULL;
	size_t i;

	hash ^= parent->ino;
	hash *= 1099511628211ULL;
	hash ^= is_dir ? 'd' : 'f';
	hash *= 1099511628211ULL;
	for (i = 0; i < name_len; i++) {
		hash ^= (u8)name[i];
		hash *= 1099511628211ULL;
	}

	/*
	 * Keep synthetic input inode numbers separate from staged and root
	 * inode numbers, and never emit zero. Directory
	 * iteration clients are allowed to ignore zero-inode dirents.
	 */
	return hash | (1ULL << 63);
}

static struct actiondfs_node *
actiondfs_alloc_staged_node(struct actiondfs_node *parent,
			    umode_t mode, u64 size, u64 real_ino)
{
	struct actiondfs_node *node;

	node = actiondfs_alloc_node(mode);
	if (!node)
		return NULL;
	node->origin = ACTIONDFS_NODE_STAGED;
	node->ino = real_ino & ~(1ULL << 63);
	node->parent = parent;
	node->size = size;
	return node;
}

static void actiondfs_set_stage_dentry(struct actiondfs_node *node,
				       struct dentry *dentry)
{
	struct dentry *old;

	dget(dentry);
	old = cmpxchg(&node->stage_dentry, NULL, dentry);
	if (old)
		dput(dentry);
	smp_store_release(&node->stage_parent_ready, true);
}

static void actiondfs_note_stage_change(struct actiondfs_node *node)
{
	atomic64_inc(&node->stage_generation);
}

static int actiondfs_stage_node_path(struct actiondfs_sb_info *sbi,
				     struct actiondfs_node *node,
				     struct path *path)
{
	struct dentry *dentry;

	if (!sbi->stage_path_valid)
		return -EROFS;

	dentry = READ_ONCE(node->stage_dentry);
	if (!dentry)
		return -ENOENT;

	path->mnt = sbi->stage_path.mnt;
	path->dentry = dentry;
	path_get(path);
	return 0;
}

static int actiondfs_stage_lookup_child(struct path *parent_path,
					const char *name, size_t name_len,
					struct dentry **out)
{
	struct qstr qname = QSTR_LEN(name, name_len);
	struct inode *parent_inode = d_inode(parent_path->dentry);
	struct dentry *dentry;

	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_CHILD_LOOKUPS);
	inode_lock_nested(parent_inode, I_MUTEX_PARENT);
	dentry = lookup_one(&nop_mnt_idmap, &qname, parent_path->dentry);
	if (IS_ERR(dentry)) {
		inode_unlock(parent_inode);
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_CHILD_LOOKUP_ERRORS);
		return PTR_ERR(dentry);
	}
	if (d_inode(dentry))
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_CHILD_LOOKUP_HITS);
	else
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_CHILD_LOOKUP_NEGATIVE);
	*out = dentry;
	return 0;
}

static void actiondfs_stage_unlock_child(struct path *parent_path,
					 struct dentry *child)
{
	dput(child);
	inode_unlock(d_inode(parent_path->dentry));
}

static int actiondfs_stage_mkdir_child(struct path *parent_path,
				       const char *name, size_t name_len,
				       umode_t mode)
{
	struct dentry *real_dentry;
	struct dentry *created;
	int err;

	err = mnt_want_write(parent_path->mnt);
	if (err)
		return err;
	err = actiondfs_stage_lookup_child(parent_path, name, name_len,
					   &real_dentry);
	if (err)
		goto out_drop_write;
	if (d_inode(real_dentry)) {
		err = S_ISDIR(d_inode(real_dentry)->i_mode) ? 0 : -ENOTDIR;
		actiondfs_stage_unlock_child(parent_path, real_dentry);
		goto out_drop_write;
	}

	created = vfs_mkdir(mnt_idmap(parent_path->mnt),
			    d_inode(parent_path->dentry), real_dentry,
			    mode & S_IALLUGO);
	if (IS_ERR(created)) {
		err = PTR_ERR(created);
		inode_unlock(d_inode(parent_path->dentry));
	} else {
		err = 0;
		dput(created);
		inode_unlock(d_inode(parent_path->dentry));
	}

out_drop_write:
	mnt_drop_write(parent_path->mnt);
	return err;
}

struct actiondfs_stage_ancestor {
	struct actiondfs_node *node;
	struct dentry *dentry;
};

static int actiondfs_ensure_stage_parent_path(struct actiondfs_sb_info *sbi,
					      struct actiondfs_node *node,
					      struct dentry *dentry,
					      struct path *path)
{
	struct actiondfs_stage_ancestor *ancestors;
	struct actiondfs_node *ancestor_node;
	struct dentry *ancestor_dentry;
	struct path current_path;
	size_t depth = 0;
	size_t path_len = 0;
	size_t i;
	int err;

	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_ENSURE_DIR_CALLS);
	if (!sbi->stage_path_valid) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_ENSURE_DIR_ERRORS);
		return -EROFS;
	}
	if (smp_load_acquire(&node->stage_parent_ready)) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_PARENT_DENTRY_HITS);
		return actiondfs_stage_node_path(sbi, node, path);
	}

	ancestor_node = node;
	ancestor_dentry = dentry;
	while (!smp_load_acquire(&ancestor_node->stage_parent_ready)) {
		size_t name_len;

		if (!ancestor_node->parent ||
		    ancestor_dentry->d_parent == ancestor_dentry) {
			err = -ESTALE;
			goto out_error;
		}
		name_len = ancestor_dentry->d_name.len;
		if (!name_len || name_len > NAME_MAX ||
		    depth == ACTIONDFS_MAX_STAGE_DEPTH ||
		    name_len + 1 > PATH_MAX - path_len) {
			err = -ENAMETOOLONG;
			goto out_error;
		}
		path_len += name_len + 1;
		depth++;
		ancestor_node = ancestor_node->parent;
		ancestor_dentry = ancestor_dentry->d_parent;
	}

	ancestors = kcalloc(depth, sizeof(*ancestors), GFP_KERNEL);
	if (!ancestors) {
		err = -ENOMEM;
		goto out_error;
	}
	ancestor_node = node;
	ancestor_dentry = dentry;
	for (i = 0; i < depth; i++) {
		ancestors[i].node = ancestor_node;
		ancestors[i].dentry = ancestor_dentry;
		ancestor_node = ancestor_node->parent;
		ancestor_dentry = ancestor_dentry->d_parent;
	}

	err = actiondfs_stage_node_path(sbi, ancestor_node, &current_path);
	if (err)
		goto out_free;

	while (depth) {
		struct actiondfs_stage_ancestor *ancestor = &ancestors[--depth];
		struct path next_path;

		if (smp_load_acquire(&ancestor->node->stage_parent_ready)) {
			err = actiondfs_stage_node_path(sbi, ancestor->node,
							  &next_path);
		} else {
			actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_ENSURE_DIR_COMPONENTS);
			err = vfs_path_lookup(current_path.dentry, current_path.mnt,
					      ancestor->dentry->d_name.name,
					      LOOKUP_DIRECTORY | LOOKUP_NO_SYMLINKS |
					      LOOKUP_NO_XDEV, &next_path);
			if (err == -ENOENT) {
				err = actiondfs_stage_mkdir_child(
					&current_path,
					ancestor->dentry->d_name.name,
					ancestor->dentry->d_name.len,
					ancestor->node->mode & S_IALLUGO);
				if (!err) {
					actiondfs_stat_inc(
						ACTIONDFS_STAT_STAGE_ENSURE_DIR_CREATED);
					err = vfs_path_lookup(
						current_path.dentry, current_path.mnt,
						ancestor->dentry->d_name.name,
						LOOKUP_DIRECTORY | LOOKUP_NO_SYMLINKS |
						LOOKUP_NO_XDEV, &next_path);
				}
			} else if (!err) {
				actiondfs_stat_inc(
					ACTIONDFS_STAT_STAGE_ENSURE_DIR_EXISTING);
			}
			if (!err)
				actiondfs_set_stage_dentry(ancestor->node,
							  next_path.dentry);
		}
		if (err) {
			path_put(&current_path);
			goto out_free;
		}
		path_put(&current_path);
		current_path = next_path;
	}

	*path = current_path;
	kfree(ancestors);
	return 0;

out_free:
	kfree(ancestors);
out_error:
	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_ENSURE_DIR_ERRORS);
	return err;
}

static int actiondfs_compare_name(const char *lhs, size_t lhs_len,
				  const char *rhs, size_t rhs_len)
{
	size_t common = min(lhs_len, rhs_len);
	int cmp;

	cmp = memcmp(lhs, rhs, common);
	if (cmp)
		return cmp;
	return (lhs_len > rhs_len) - (lhs_len < rhs_len);
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

static struct actiondfs_cached_child *
actiondfs_find_cached_child(struct actiondfs_node *dir,
			    const char *name, size_t len)
{
	struct actiondfs_cached_dir *cached = dir->cached_dir;
	size_t index;

	if (!cached)
		return NULL;

	if (actiondfs_find_cached_child_in(cached->file_children,
					   cached->file_count,
					   name, len, &index))
		return &cached->file_children[index];

	if (actiondfs_find_cached_child_in(cached->dir_children,
						   cached->dir_count,
						   name, len, &index))
		return &cached->dir_children[index];

	if (actiondfs_find_cached_child_in(cached->symlink_children,
						   cached->symlink_count,
						   name, len, &index))
		return &cached->symlink_children[index];

	return NULL;
}

static struct actiondfs_node *
actiondfs_materialize_cached_child(struct actiondfs_node *parent,
				   struct actiondfs_cached_child *record)
{
	struct actiondfs_node *node;

	node = actiondfs_alloc_node(record->mode);
	if (!node)
		return ERR_PTR(-ENOMEM);

	node->parent = parent;
	node->input_name = record->name;
	node->input_name_len = record->name_len;
	node->ino = actiondfs_input_child_ino(parent, record->name,
					     record->name_len,
					     S_ISDIR(record->mode));
	node->size = record->size;
	if (S_ISLNK(record->mode)) {
		node->link_target = kstrdup(record->link_target, GFP_KERNEL);
		if (!node->link_target) {
			actiondfs_free_node(node);
			return ERR_PTR(-ENOMEM);
		}
	}
	memcpy(node->hash, record->hash, 64);
	node->hash[64] = '\0';
	if (S_ISDIR(record->mode))
		node->loaded = false;
	return node;
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

static bool actiondfs_cached_children_overlap(
	const struct actiondfs_cached_child *lhs, size_t lhs_count,
	const struct actiondfs_cached_child *rhs, size_t rhs_count)
{
	while (lhs_count && rhs_count) {
		int cmp = actiondfs_compare_name(lhs->name, lhs->name_len,
						 rhs->name, rhs->name_len);

		if (!cmp)
			return true;
		if (cmp < 0) {
			lhs++;
			lhs_count--;
		} else {
			rhs++;
			rhs_count--;
		}
	}
	return false;
}

static int
actiondfs_validate_no_cross_type_cached_duplicates(struct actiondfs_cached_dir *dir)
{
	if (actiondfs_cached_children_overlap(dir->file_children,
					      dir->file_count,
					      dir->dir_children,
					      dir->dir_count) ||
	    actiondfs_cached_children_overlap(dir->file_children,
					      dir->file_count,
					      dir->symlink_children,
					      dir->symlink_count) ||
	    actiondfs_cached_children_overlap(dir->dir_children,
					      dir->dir_count,
					      dir->symlink_children,
					      dir->symlink_count))
		return -EEXIST;
	return 0;
}

static int actiondfs_valid_component(const char *name, size_t len)
{
	if (!len || len > NAME_MAX)
		return -EINVAL;
	if ((len == 1 && name[0] == '.') ||
	    (len == 2 && name[0] == '.' && name[1] == '.'))
		return -EINVAL;
	if (memchr(name, '\0', len) || memchr(name, '/', len))
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
	for (i = 0; i < dir->symlink_count; i++) {
		kfree(dir->symlink_children[i].name);
		kfree(dir->symlink_children[i].link_target);
	}
	kfree(dir->file_children);
	kfree(dir->dir_children);
	kfree(dir->symlink_children);
	if (dir->cas_root)
		dput(dir->cas_root);
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
	dput(entry->dentry);
	dput(entry->cas_root);
	kfree(entry);
}

static void actiondfs_release_blob_path_cache_entry_work(struct work_struct *work)
{
	struct actiondfs_blob_path_cache_entry *entry =
		container_of(work, struct actiondfs_blob_path_cache_entry,
			     release_work);

	actiondfs_free_blob_path_cache_entry(entry);
}

static void actiondfs_release_blob_path_cache_entry_rcu(struct rcu_head *rcu)
{
	struct actiondfs_blob_path_cache_entry *entry =
		container_of(rcu, struct actiondfs_blob_path_cache_entry, rcu);

	queue_work(actiondfs_blob_path_cache_release_wq, &entry->release_work);
}

static void actiondfs_release_blob_path_cache_entry(
	struct actiondfs_blob_path_cache_entry *entry)
{
	call_rcu(&entry->rcu, actiondfs_release_blob_path_cache_entry_rcu);
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
					     u64 size,
					     const char *hash)
{
	int err;

	err = actiondfs_append_cached_child(&parent->dir_children,
					    &parent->dir_count,
					    &parent->dir_capacity,
					    name, name_len, mode, size, hash);
	if (!err)
		actiondfs_stat_inc(ACTIONDFS_STAT_CACHED_DIR_RECORDS);
	return err;
}

static int actiondfs_append_cached_symlink_child(struct actiondfs_cached_dir *parent,
						 const char *name,
						 size_t name_len,
						 const char *target,
						 size_t target_len)
{
	struct actiondfs_cached_child *child;
	int err;

	if (!target_len || target_len >= PATH_MAX ||
	    memchr(target, '\0', target_len))
		return -EINVAL;

	err = actiondfs_append_cached_child(&parent->symlink_children,
					    &parent->symlink_count,
					    &parent->symlink_capacity,
					    name, name_len, S_IFLNK | 0777,
					    target_len, ACTIONDFS_EMPTY_SHA256);
	if (err)
		return err;

	child = &parent->symlink_children[parent->symlink_count - 1];
	child->link_target = kmemdup_nul(target, target_len, GFP_KERNEL);
	if (!child->link_target) {
		kfree(child->name);
		child->name = NULL;
		parent->symlink_count--;
		return -ENOMEM;
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

	if (strlen(hash) != ACTIONDFS_HASH_HEX_LEN)
		return -EINVAL;
	for (i = 0; i < ACTIONDFS_HASH_HEX_LEN; i++) {
		if (actiondfs_hex_nibble(hash[i]) < 0)
			return -EINVAL;
	}
	return 0;
}

static bool actiondfs_is_empty_sha256(const char *hash)
{
	return !memcmp(hash, ACTIONDFS_EMPTY_SHA256, ACTIONDFS_HASH_HEX_LEN);
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
	struct inode *real_inode;
	struct path real_path;
	int err;

	actiondfs_sharded_hash_path(hash, path);
	while (true) {
		actiondfs_stat_inc(ACTIONDFS_STAT_BLOB_OPEN_ATTEMPTS);
		err = vfs_path_lookup(sbi->cas_path.dentry, sbi->cas_path.mnt,
				      path, LOOKUP_FOLLOW | LOOKUP_NO_SYMLINKS |
					    LOOKUP_NO_XDEV, &real_path);
		if (err) {
			file = ERR_PTR(err);
		} else {
			real_inode = d_inode(real_path.dentry);
			if (!real_inode || !S_ISREG(real_inode->i_mode)) {
				path_put(&real_path);
				return ERR_PTR(-EIO);
			}
			file = dentry_open(&real_path, O_RDONLY | O_NONBLOCK,
					   current_cred());
			path_put(&real_path);
		}
		if (!IS_ERR(file)) {
			if (!S_ISREG(file_inode(file)->i_mode)) {
				fput(file);
				return ERR_PTR(-EIO);
			}
			return file;
		}

		err = PTR_ERR(file);
		if (!actiondfs_retry_open_stale(err, &stale_attempts))
			return file;
	}
}

static struct file *actiondfs_open_backing_cas_blob(struct actiondfs_sb_info *sbi,
						    const char *hash,
						    const struct path *user_path,
						    u64 expected_size)
{
	unsigned int stale_attempts = 0;
	struct file *file;
	struct inode *real_inode;
	struct path real_path;
	loff_t real_size;
	u64 total_start = actiondfs_stat_time_start();
	int err;

	while (true) {
		u64 open_start;
		u64 path_start;

		actiondfs_stat_inc(ACTIONDFS_STAT_BLOB_OPEN_ATTEMPTS);
		path_start = actiondfs_stat_time_start();
		err = actiondfs_get_cached_blob_path(sbi, hash, &real_path);
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_BLOB_OPEN_BACKING_PATH_NS,
					   path_start);
		if (err) {
			if (!actiondfs_retry_open_stale(err, &stale_attempts)) {
				actiondfs_stat_add_elapsed(
					ACTIONDFS_STAT_BLOB_OPEN_BACKING_TOTAL_NS,
					total_start);
				return ERR_PTR(err);
			}
			continue;
		}

		real_inode = d_inode(real_path.dentry);
		real_size = real_inode ? i_size_read(real_inode) : -1;
		if (!real_inode || !S_ISREG(real_inode->i_mode) ||
		    real_size < 0 || (u64)real_size != expected_size) {
			path_put(&real_path);
			actiondfs_stat_add_elapsed(
				ACTIONDFS_STAT_BLOB_OPEN_BACKING_TOTAL_NS, total_start);
			return ERR_PTR(-EIO);
		}

		open_start = actiondfs_stat_time_start();
		file = backing_file_open(user_path, O_RDONLY, &real_path,
					 current_cred());
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_BLOB_OPEN_BACKING_FILE_NS,
					   open_start);
		path_put(&real_path);
		if (!IS_ERR(file)) {
			actiondfs_stat_add_elapsed(
				ACTIONDFS_STAT_BLOB_OPEN_BACKING_TOTAL_NS,
				total_start);
			return file;
		}

		err = PTR_ERR(file);
		if (err == -ESTALE)
			actiondfs_drop_cached_blob_path(sbi, hash);
		if (!actiondfs_retry_open_stale(err, &stale_attempts)) {
			actiondfs_stat_add_elapsed(
				ACTIONDFS_STAT_BLOB_OPEN_BACKING_TOTAL_NS,
				total_start);
			return file;
		}
	}
}

static struct file *actiondfs_get_node_blob_file(struct actiondfs_node *node,
						 struct file *actiondfs_file)
{
	struct file *file;

	mutex_lock(&node->load_lock);
	file = actiondfs_file->private_data;
	if (file) {
		get_file(file);
		actiondfs_stat_inc(ACTIONDFS_STAT_NODE_BLOB_CACHE_HITS);
	}
	mutex_unlock(&node->load_lock);
	return file ? file : ERR_PTR(-EBADF);
}

static int actiondfs_reopen_node_blob_if_current(struct actiondfs_sb_info *sbi,
						 struct actiondfs_node *node,
						 struct file *actiondfs_file,
						 struct file *current_file)
{
	struct file *replacement;
	int err = 0;

	mutex_lock(&node->load_lock);
	if (actiondfs_file->private_data == current_file) {
		actiondfs_drop_cached_blob_path(sbi, node->hash);
		replacement = actiondfs_open_backing_cas_blob(
			sbi, node->hash, file_user_path(actiondfs_file), node->size);
		if (IS_ERR(replacement)) {
			err = PTR_ERR(replacement);
		} else {
			actiondfs_file->private_data = replacement;
			fput(current_file);
		}
	}
	mutex_unlock(&node->load_lock);
	return err;
}

static struct file *actiondfs_open_staged_backing(struct actiondfs_sb_info *sbi,
						  struct file *actiondfs_file,
						  int flags)
{
	struct actiondfs_node *node = file_inode(actiondfs_file)->i_private;
	struct path real_path;
	struct file *file;
	u64 total_start = actiondfs_stat_time_start();
	u64 phase_start;
	int err;

	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_BACKING_OPEN_ATTEMPTS);
	if (!sbi->stage_path_valid) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_BACKING_OPEN_FAILURES);
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_BACKING_OPEN_TOTAL_NS,
					   total_start);
		return ERR_PTR(-EROFS);
	}

	phase_start = actiondfs_stat_time_start();
	err = actiondfs_stage_node_path(sbi, node, &real_path);
	actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_BACKING_OPEN_LOOKUP_NS,
				   phase_start);
	if (err) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_BACKING_OPEN_FAILURES);
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_BACKING_OPEN_TOTAL_NS,
					   total_start);
		return ERR_PTR(err);
	}

	phase_start = actiondfs_stat_time_start();
	file = backing_file_open(file_user_path(actiondfs_file), flags,
				 &real_path, current_cred());
	actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_BACKING_OPEN_FILE_NS,
				   phase_start);
	path_put(&real_path);
	if (IS_ERR(file))
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_BACKING_OPEN_FAILURES);
	actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_BACKING_OPEN_TOTAL_NS,
				   total_start);
	return file;
}

static int actiondfs_staged_backing_flags(const struct file *file)
{
	if ((file->f_mode & FMODE_READ) && (file->f_mode & FMODE_WRITE))
		return O_RDWR;
	if (file->f_mode & FMODE_WRITE)
		return O_WRONLY;
	return O_RDONLY;
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

	if (node->origin == ACTIONDFS_NODE_STAGED) {
		u64 total_start;

		if (!requested)
			return 0;
		total_start = actiondfs_stat_time_start();
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_READ_CALLS);
		file = iocb->ki_filp->private_data;
		if (!file) {
			actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_READ_TOTAL_NS,
						   total_start);
			return -EBADF;
		}
		nread = backing_file_read_iter(file, to, iocb, iocb->ki_flags,
					       &ctx);
		if (nread > 0)
			actiondfs_stat_add(ACTIONDFS_STAT_STAGE_READ_BYTES,
					   (u64)nread);
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_READ_TOTAL_NS,
					   total_start);
		return nread;
	}

	if (!requested)
		return 0;
	if (iocb->ki_pos < 0)
		return -EINVAL;
	if (iocb->ki_pos >= node->size)
		return 0;

	wanted = min_t(u64, (u64)requested, node->size - iocb->ki_pos);
	iov_iter_truncate(to, wanted);

	do {
		file = actiondfs_get_node_blob_file(node, iocb->ki_filp);
		if (IS_ERR(file))
			return PTR_ERR(file);

		actiondfs_stat_inc(ACTIONDFS_STAT_BACKING_READS);
		nread = backing_file_read_iter(file, to, iocb, iocb->ki_flags,
					       &ctx);
		if (nread == -ESTALE) {
			int err = actiondfs_reopen_node_blob_if_current(
				sbi, node, iocb->ki_filp, file);

			if (err)
				nread = err;
		}
		fput(file);
	} while (actiondfs_retry_backing_read_stale(nread, &stale_attempts));

	if (nread > 0)
		actiondfs_stat_add(ACTIONDFS_STAT_BACKING_READ_BYTES, (u64)nread);
	return nread;
}

static void actiondfs_sync_staged_inode(struct inode *inode,
					struct inode *backing_inode)
{
	struct actiondfs_node *node = inode->i_private;
	loff_t size;

	spin_lock(&inode->i_lock);
	size = i_size_read(backing_inode);
	node->size = size;
	i_size_write(inode, size);
	inode_set_mtime_to_ts(inode, inode_get_mtime(backing_inode));
	inode_set_ctime_to_ts(inode, inode_get_ctime(backing_inode));
	spin_unlock(&inode->i_lock);
}

static void actiondfs_stage_end_write(struct kiocb *iocb, ssize_t written)
{
	struct file *backing_file;

	if (written <= 0)
		return;

	backing_file = iocb->ki_filp->private_data;
	if (!backing_file)
		return;

	actiondfs_sync_staged_inode(file_inode(iocb->ki_filp),
				    file_inode(backing_file));
	actiondfs_stat_add(ACTIONDFS_STAT_STAGE_WRITE_BYTES, (u64)written);
}

static ssize_t actiondfs_write_iter(struct kiocb *iocb, struct iov_iter *from)
{
	struct inode *inode = file_inode(iocb->ki_filp);
	struct actiondfs_node *node = inode->i_private;
	struct file *file;
	ssize_t nwritten;
	struct backing_file_ctx ctx = {
		.cred = current_cred(),
		.end_write = actiondfs_stage_end_write,
	};

	if (node->origin != ACTIONDFS_NODE_STAGED)
		return -EROFS;

	{
		u64 total_start = actiondfs_stat_time_start();

		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_WRITE_CALLS);
		file = iocb->ki_filp->private_data;
		if (!file) {
			actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_WRITE_TOTAL_NS,
						   total_start);
			return -EBADF;
		}
		nwritten = backing_file_write_iter(file, from, iocb,
						   iocb->ki_flags, &ctx);
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_WRITE_TOTAL_NS,
					   total_start);
	}
	return nwritten;
}

static ssize_t actiondfs_copy_file_range(struct file *file_in, loff_t pos_in,
					 struct file *file_out, loff_t pos_out,
					 size_t len, unsigned int flags)
{
	struct inode *inode_in = file_inode(file_in);
	struct inode *inode_out = file_inode(file_out);
	struct actiondfs_node *node_in = inode_in->i_private;
	struct actiondfs_node *node_out;
	struct file *real_in;
	struct file *real_out;
	u64 total_start = actiondfs_stat_time_start();
	ssize_t copied;

	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_ATTEMPTS);
	if (!len) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_SUCCESS);
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_TOTAL_NS,
					   total_start);
		return 0;
	}
	if (flags || file_out->f_op != &actiondfs_file_fops ||
	    inode_out->i_sb != inode_in->i_sb) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_FALLBACKS);
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_TOTAL_NS,
					   total_start);
		return -EOPNOTSUPP;
	}
	if (pos_in < 0 || pos_out < 0) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_FALLBACKS);
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_TOTAL_NS,
					   total_start);
		return -EINVAL;
	}

	node_out = inode_out->i_private;
	if (node_out->origin != ACTIONDFS_NODE_STAGED || node_in == node_out) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_FALLBACKS);
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_TOTAL_NS,
					   total_start);
		return -EOPNOTSUPP;
	}
	if (node_in->origin == ACTIONDFS_NODE_INPUT) {
		if (pos_in >= node_in->size) {
			actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_SUCCESS);
			actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_TOTAL_NS,
						   total_start);
			return 0;
		}
		len = min_t(u64, (u64)len, node_in->size - pos_in);
		real_in = actiondfs_get_node_blob_file(node_in, file_in);
	} else if (node_in->origin == ACTIONDFS_NODE_STAGED) {
		if (pos_in >= node_in->size) {
			actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_SUCCESS);
			actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_TOTAL_NS,
						   total_start);
			return 0;
		}
		len = min_t(u64, (u64)len, node_in->size - pos_in);
		real_in = file_in->private_data;
		if (!real_in)
			real_in = ERR_PTR(-EBADF);
		else
			get_file(real_in);
	} else {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_FALLBACKS);
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_TOTAL_NS,
					   total_start);
		return -EOPNOTSUPP;
	}
	if (IS_ERR(real_in)) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_FALLBACKS);
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_TOTAL_NS,
					   total_start);
		return PTR_ERR(real_in);
	}

	real_out = file_out->private_data;
	if (!real_out)
		real_out = ERR_PTR(-EBADF);
	else
		get_file(real_out);
	if (IS_ERR(real_out)) {
		fput(real_in);
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_FALLBACKS);
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_TOTAL_NS,
					   total_start);
		return PTR_ERR(real_out);
	}

	copied = vfs_copy_file_range(real_in, pos_in, real_out, pos_out, len, 0);
	if (copied > 0)
		actiondfs_sync_staged_inode(inode_out, file_inode(real_out));
	fput(real_out);
	fput(real_in);
	if (copied > 0) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_SUCCESS);
		actiondfs_stat_add(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_BYTES,
				   (u64)copied);
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_TOTAL_NS,
					   total_start);
		return copied;
	}

	if (copied == 0) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_SUCCESS);
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_TOTAL_NS,
					   total_start);
		return 0;
	}

	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_FALLBACKS);
	actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_TOTAL_NS,
				   total_start);
	return copied;
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

	if (node->origin == ACTIONDFS_NODE_STAGED) {
		struct kiocb backing_iocb;
		u64 total_start = actiondfs_stat_time_start();

		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_SPLICE_READ_CALLS);
		file = actiondfs_file->private_data;
		if (!file) {
			actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_SPLICE_READ_TOTAL_NS,
						   total_start);
			return -EBADF;
		}
		init_sync_kiocb(&backing_iocb, actiondfs_file);
		backing_iocb.ki_pos = pos;
		nread = backing_file_splice_read(file, &backing_iocb, pipe,
						 len, flags, &ctx);
		if (nread > 0) {
			*ppos = backing_iocb.ki_pos;
			actiondfs_stat_add(ACTIONDFS_STAT_STAGE_SPLICE_READ_BYTES,
					   (u64)nread);
		}
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_SPLICE_READ_TOTAL_NS,
					   total_start);
		return nread;
	}

	if (!len)
		return 0;
	if (pos < 0)
		return -EINVAL;
	if (pos >= node->size)
		return 0;

	wanted = min_t(u64, (u64)len, node->size - pos);

	do {
		struct kiocb backing_iocb;

		file = actiondfs_get_node_blob_file(node, actiondfs_file);
		if (IS_ERR(file))
			return PTR_ERR(file);

		init_sync_kiocb(&backing_iocb, actiondfs_file);
		backing_iocb.ki_pos = pos;
		actiondfs_stat_inc(ACTIONDFS_STAT_SPLICE_READS);
		nread = backing_file_splice_read(file, &backing_iocb, pipe,
						 wanted, flags, &ctx);
		if (nread > 0)
			pos = backing_iocb.ki_pos;
		if (nread == -ESTALE) {
			int err = actiondfs_reopen_node_blob_if_current(
				sbi, node, actiondfs_file, file);

			if (err)
				nread = err;
		}
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

	if (node->origin == ACTIONDFS_NODE_STAGED) {
		u64 total_start = actiondfs_stat_time_start();

		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_MMAP_CALLS);
		file = actiondfs_file->private_data;
		if (!file) {
			actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_MMAP_FAILURES);
			actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_MMAP_TOTAL_NS,
						   total_start);
			return -EBADF;
		}
		err = backing_file_mmap(file, vma, &ctx);
		if (err)
			actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_MMAP_FAILURES);
		else
			actiondfs_stat_add(ACTIONDFS_STAT_STAGE_MMAP_BYTES,
					   (u64)(vma->vm_end - vma->vm_start));
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_MMAP_TOTAL_NS,
					   total_start);
		return err;
	}

	file = actiondfs_get_node_blob_file(node, actiondfs_file);
	if (IS_ERR(file)) {
		actiondfs_stat_inc(ACTIONDFS_STAT_MMAP_FAILURES);
		return PTR_ERR(file);
	}

	actiondfs_stat_inc(ACTIONDFS_STAT_MMAPS);
	err = backing_file_mmap(file, vma, &ctx);
	if (err) {
		actiondfs_stat_inc(ACTIONDFS_STAT_MMAP_FAILURES);
		if (err == -ESTALE) {
			int reopen_err = actiondfs_reopen_node_blob_if_current(
				sbi, node, actiondfs_file, file);

			if (reopen_err)
				err = reopen_err;
		}
	} else {
		actiondfs_stat_add(ACTIONDFS_STAT_MMAP_BYTES,
				   (u64)(vma->vm_end - vma->vm_start));
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

struct actiondfs_parsed_symlink {
	const u8 *name;
	size_t name_len;
	const u8 *target;
	size_t target_len;
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
			if (value > (u64)MAX_LFS_FILESIZE)
				return -EINVAL;
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

	return actiondfs_append_cached_dir_child(parent,
						 dir.name, dir.name_len,
						 S_IFDIR | ACTIONDFS_DIR_MODE,
						 dir.digest.size,
							 dir.digest.hash);
}

static int actiondfs_parse_reapi_cached_symlink(struct actiondfs_cached_dir *parent,
						const u8 *data, size_t len)
{
	struct actiondfs_parsed_symlink symlink = {};
	size_t pos = 0;
	int err;

	while (pos < len) {
		const u8 *field;
		size_t field_len;
		u64 key;

		err = actiondfs_pb_read_varint(data, len, &pos, &key);
		if (err)
			return err;

		switch (key >> 3) {
		case 1:
		case 2:
			if ((key & 7) != 2)
				return -EINVAL;
			err = actiondfs_pb_read_len(data, len, &pos, &field,
						   &field_len);
			if (err)
				return err;
			if ((key >> 3) == 1) {
				symlink.name = field;
				symlink.name_len = field_len;
			} else {
				symlink.target = field;
				symlink.target_len = field_len;
			}
			break;
		default:
			err = actiondfs_pb_skip(data, len, &pos, key & 7);
			if (err)
				return err;
		}
	}

	if (!symlink.name || !symlink.target)
		return -EINVAL;
	return actiondfs_append_cached_symlink_child(parent,
							     symlink.name,
							     symlink.name_len,
							     symlink.target,
							     symlink.target_len);
}

static int actiondfs_read_cas_blob_once(struct actiondfs_sb_info *sbi,
					const char *hash,
					u64 expected_size,
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
	if (expected_size != ACTIONDFS_UNKNOWN_SIZE &&
	    expected_size > ACTIONDFS_MAX_DIRECTORY_PROTO_SIZE)
		return -EINVAL;

	if (actiondfs_is_empty_sha256(hash)) {
		if (expected_size != ACTIONDFS_UNKNOWN_SIZE && expected_size != 0)
			return -EINVAL;
		buffer = kvzalloc(1, GFP_KERNEL);
		if (!buffer)
			return -ENOMEM;
		*out = buffer;
		*out_len = 0;
		return 0;
	}

	file = actiondfs_open_directory_blob(sbi, hash);
	if (IS_ERR(file))
		return PTR_ERR(file);

	size = i_size_read(file_inode(file));
	if (size < 0 || size > ACTIONDFS_MAX_DIRECTORY_PROTO_SIZE) {
		filp_close(file, NULL);
		return -EINVAL;
	}
	if (expected_size != ACTIONDFS_UNKNOWN_SIZE &&
	    (u64)size != expected_size) {
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
				   u64 expected_size,
				   u8 **out,
				   size_t *out_len)
{
	unsigned int stale_attempts = 0;
	int err;

	while (true) {
		err = actiondfs_read_cas_blob_once(sbi, hash, expected_size,
						   out, out_len);
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

static struct actiondfs_blob_path_cache_entry *
actiondfs_find_blob_path_cache_locked(struct actiondfs_sb_info *sbi,
				      const char *hash)
{
	struct actiondfs_blob_path_cache_entry *entry;
	unsigned long key = actiondfs_digest_cache_key(hash);

	hash_for_each_possible(actiondfs_blob_path_cache, entry, hnode, key) {
		if (entry->cas_root == sbi->cas_path.dentry &&
		    !memcmp(entry->hash, hash, 64))
			return entry;
	}
	return NULL;
}

static struct actiondfs_blob_path_cache_entry *
actiondfs_find_blob_path_cache_rcu(struct actiondfs_sb_info *sbi,
				   const char *hash)
{
	struct actiondfs_blob_path_cache_entry *entry;
	unsigned long key = actiondfs_digest_cache_key(hash);

	hash_for_each_possible_rcu(actiondfs_blob_path_cache, entry, hnode, key) {
		if (entry->cas_root == sbi->cas_path.dentry &&
		    !memcmp(entry->hash, hash, 64))
			return entry;
	}
	return NULL;
}

static void actiondfs_get_blob_path_cache_entry_locked(
	struct actiondfs_sb_info *sbi,
	struct actiondfs_blob_path_cache_entry *entry,
	struct path *out)
{
	list_move_tail(&entry->list, &actiondfs_blob_path_cache_list);
	out->mnt = sbi->cas_path.mnt;
	out->dentry = entry->dentry;
	path_get(out);
}

static void actiondfs_evict_blob_path_cache_one_locked(void)
{
	struct actiondfs_blob_path_cache_entry *victim;

	victim = list_first_entry_or_null(&actiondfs_blob_path_cache_list,
					  struct actiondfs_blob_path_cache_entry,
					  list);
	if (!victim)
		return;

	hash_del_rcu(&victim->hnode);
	list_del(&victim->list);
	actiondfs_blob_path_cache_count--;
	actiondfs_stat_inc(ACTIONDFS_STAT_BLOB_PATH_CACHE_EVICTIONS);
	actiondfs_release_blob_path_cache_entry(victim);
}

static int actiondfs_insert_blob_path_cache(struct actiondfs_sb_info *sbi,
					    const char *hash,
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
	entry->cas_root = dget(sbi->cas_path.dentry);
	entry->dentry = dget(path->dentry);
	INIT_LIST_HEAD(&entry->list);
	INIT_WORK(&entry->release_work,
		  actiondfs_release_blob_path_cache_entry_work);

	mutex_lock(&actiondfs_blob_path_cache_lock);
	existing = actiondfs_find_blob_path_cache_locked(sbi, hash);
	if (existing) {
		actiondfs_get_blob_path_cache_entry_locked(sbi, existing, out);
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
	actiondfs_get_blob_path_cache_entry_locked(sbi, entry, out);
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
	entry = actiondfs_find_blob_path_cache_rcu(sbi, hash);
	if (entry) {
		out->mnt = sbi->cas_path.mnt;
		out->dentry = entry->dentry;
		path_get(out);
		rcu_read_unlock();
		actiondfs_stat_inc(ACTIONDFS_STAT_BLOB_PATH_CACHE_HITS);
		return 0;
	}
	rcu_read_unlock();

	mutex_lock(&actiondfs_blob_path_cache_lock);
	entry = actiondfs_find_blob_path_cache_locked(sbi, hash);
	if (entry) {
		actiondfs_get_blob_path_cache_entry_locked(sbi, entry, out);
		mutex_unlock(&actiondfs_blob_path_cache_lock);
		actiondfs_stat_inc(ACTIONDFS_STAT_BLOB_PATH_CACHE_HITS);
		return 0;
	}
	mutex_unlock(&actiondfs_blob_path_cache_lock);

	actiondfs_stat_inc(ACTIONDFS_STAT_BLOB_PATH_CACHE_MISSES);
	actiondfs_sharded_hash_path(hash, path);
	err = vfs_path_lookup(sbi->cas_path.dentry, sbi->cas_path.mnt,
			      path, LOOKUP_FOLLOW | LOOKUP_NO_SYMLINKS |
				    LOOKUP_NO_XDEV, &real_path);
	if (err)
		return err;

	err = actiondfs_insert_blob_path_cache(sbi, hash, &real_path, out);
	path_put(&real_path);
	return err;
}

static void actiondfs_drop_cached_blob_path(struct actiondfs_sb_info *sbi,
					   const char *hash)
{
	struct actiondfs_blob_path_cache_entry *entry;

	mutex_lock(&actiondfs_blob_path_cache_lock);
	entry = actiondfs_find_blob_path_cache_locked(sbi, hash);
	if (entry) {
		hash_del_rcu(&entry->hnode);
		list_del(&entry->list);
		actiondfs_blob_path_cache_count--;
	}
	mutex_unlock(&actiondfs_blob_path_cache_lock);
	if (entry)
		actiondfs_release_blob_path_cache_entry(entry);
}

static struct actiondfs_cached_dir *
actiondfs_find_cached_dir_locked(struct actiondfs_sb_info *sbi,
				 const char *hash)
{
	struct actiondfs_cached_dir *entry;
	unsigned long key = actiondfs_digest_cache_key(hash);

	hash_for_each_possible(actiondfs_dir_cache, entry, hnode, key) {
		if (entry->cas_root == sbi->cas_path.dentry &&
		    !memcmp(entry->hash, hash, 64))
			return entry;
	}
	return NULL;
}

static int actiondfs_build_cached_dir(struct actiondfs_sb_info *sbi,
				      const char *hash,
				      u64 expected_size,
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
	entry->cas_root = dget(sbi->cas_path.dentry);
	memcpy(entry->hash, hash, 64);
	entry->hash[64] = '\0';

	err = actiondfs_read_cas_blob(sbi, hash, expected_size, &buffer, &len);
	if (err)
		goto fail;
	if (sbi->root && !memcmp(hash, sbi->root->hash, ACTIONDFS_HASH_HEX_LEN))
		actiondfs_stat_inc(ACTIONDFS_STAT_ROOT_DIR_PARSES);
	entry->size = len;
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
			if ((key & 7) != 2) {
				err = -EINVAL;
				goto out_buffer;
			}
			err = actiondfs_pb_read_len(buffer, len, &pos, &field,
						    &field_len);
			if (err)
				goto out_buffer;
			err = actiondfs_parse_reapi_cached_symlink(entry, field,
							       field_len);
			if (err)
				goto out_buffer;
			break;
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
				    u64 expected_size,
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
	entry = actiondfs_find_cached_dir_locked(sbi, hash);
	mutex_unlock(&actiondfs_dir_cache_lock);
	if (entry) {
		if (expected_size != ACTIONDFS_UNKNOWN_SIZE &&
		    entry->size != expected_size)
			return -EINVAL;
		actiondfs_stat_inc(ACTIONDFS_STAT_DIR_CACHE_HITS);
		*out = entry;
		return 0;
	}

	actiondfs_stat_inc(ACTIONDFS_STAT_DIR_CACHE_MISSES);
	err = actiondfs_build_cached_dir(sbi, hash, expected_size, &entry);
	if (err)
		return err;

	key = actiondfs_digest_cache_key(hash);
	mutex_lock(&actiondfs_dir_cache_lock);
	existing = actiondfs_find_cached_dir_locked(sbi, hash);
	if (existing) {
		mutex_unlock(&actiondfs_dir_cache_lock);
		actiondfs_free_cached_dir(entry);
		if (expected_size != ACTIONDFS_UNKNOWN_SIZE &&
		    existing->size != expected_size)
			return -EINVAL;
		actiondfs_stat_inc(ACTIONDFS_STAT_DIR_CACHE_RACES);
		*out = existing;
		return 0;
	}
	hash_add(actiondfs_dir_cache, &entry->hnode, key);
	mutex_unlock(&actiondfs_dir_cache_lock);

	*out = entry;
	return 0;
}

static int actiondfs_load_reapi_directory_locked(struct actiondfs_sb_info *sbi,
						 struct actiondfs_node *dir)
{
	struct actiondfs_cached_dir *cached;
	int err;

	if (smp_load_acquire(&dir->loaded))
		return 0;

	err = actiondfs_get_cached_dir(sbi, dir->hash, dir->size, &cached);
	if (err)
		return err;
	dir->cached_dir = cached;
	smp_store_release(&dir->loaded, true);
	return 0;
}

static int actiondfs_ensure_loaded(struct super_block *sb,
				   struct actiondfs_node *dir)
{
	struct actiondfs_sb_info *sbi = actiondfs_sbi(sb);
	int err = 0;

	if (!actiondfs_is_dir(dir))
		return -ENOTDIR;
	if (smp_load_acquire(&dir->loaded))
		return 0;

	mutex_lock(&dir->load_lock);
	if (!smp_load_acquire(&dir->loaded)) {
		actiondfs_stat_inc(ACTIONDFS_STAT_DIR_LOADS);
		err = actiondfs_load_reapi_directory_locked(sbi, dir);
	}
	mutex_unlock(&dir->load_lock);
	return err;
}

static void actiondfs_free_mount_options(struct actiondfs_mount_options *opts)
{
	kfree(opts->cas_root);
	kfree(opts->root_hash);
	kfree(opts->stage_root);
}

static int actiondfs_parse_options(struct actiondfs_mount_options *opts, void *data)
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
			kfree(opts->root_hash);
			opts->root_hash = kstrdup(token + 5, GFP_KERNEL);
			if (!opts->root_hash) {
				kfree(options);
				return -ENOMEM;
			}
		} else if (str_has_prefix(token, "root_size=")) {
			if (kstrtoull(token + 10, 10, &opts->root_size) ||
			    opts->root_size > MAX_LFS_FILESIZE) {
				kfree(options);
				return -EINVAL;
			}
		} else if (str_has_prefix(token, "cas=")) {
			kfree(opts->cas_root);
			opts->cas_root = kstrdup(token + 4, GFP_KERNEL);
			if (!opts->cas_root) {
				kfree(options);
				return -ENOMEM;
			}
		} else if (str_has_prefix(token, "stage=")) {
			kfree(opts->stage_root);
			opts->stage_root = kstrdup(token + 6, GFP_KERNEL);
			if (!opts->stage_root) {
				kfree(options);
				return -ENOMEM;
			}
		} else if (*token) {
			kfree(options);
			return -EINVAL;
		}
	}

	kfree(options);
	if (!opts->cas_root || !opts->root_hash)
		return -EINVAL;
	if (actiondfs_valid_hash(opts->root_hash))
		return -EINVAL;
	if (opts->root_size != ACTIONDFS_UNKNOWN_SIZE &&
	    opts->root_size > ACTIONDFS_MAX_DIRECTORY_PROTO_SIZE)
		return -EINVAL;
	if (strchr(opts->cas_root, ','))
		return -EINVAL;
	if (opts->stage_root && strchr(opts->stage_root, ','))
		return -EINVAL;
	return 0;
}

static int actiondfs_test_input_inode(struct inode *inode, void *data)
{
	struct actiondfs_node *candidate = data;
	struct actiondfs_node *existing = inode->i_private;

	return existing && existing->origin == ACTIONDFS_NODE_INPUT &&
	       existing->ino == candidate->ino &&
	       existing->parent == candidate->parent &&
	       (existing->mode & S_IFMT) == (candidate->mode & S_IFMT) &&
	       existing->input_name_len == candidate->input_name_len &&
	       !memcmp(existing->input_name, candidate->input_name,
		       candidate->input_name_len);
}

static int actiondfs_set_input_inode(struct inode *inode, void *data)
{
	struct actiondfs_node *node = data;

	inode->i_ino = node->ino;
	inode->i_private = node;
	return 0;
}

static void actiondfs_init_inode(struct inode *inode,
				 struct actiondfs_node *node)
{
	inode->i_ino = node->ino;
	inode_init_owner(&nop_mnt_idmap, inode, NULL, node->mode);
	inode->i_private = node;
	simple_inode_init_ts(inode);

	if (S_ISLNK(node->mode)) {
		inode->i_op = &actiondfs_symlink_iops;
		inode_set_cached_link(inode, node->link_target, node->size);
		i_size_write(inode, node->size);
		set_nlink(inode, 1);
	} else if (S_ISDIR(node->mode)) {
		inode->i_op = &actiondfs_dir_iops;
		inode->i_fop = &actiondfs_dir_fops;
		set_nlink(inode, 2);
	} else {
		inode->i_op = &actiondfs_file_iops;
		inode->i_fop = &actiondfs_file_fops;
		i_size_write(inode, node->size);
		set_nlink(inode, 1);
	}
}

static struct inode *actiondfs_iget(struct super_block *sb,
				    struct actiondfs_node *node)
{
	struct inode *inode;
	bool input_child = node->origin == ACTIONDFS_NODE_INPUT && node->parent;

	if (input_child)
		inode = iget5_locked(sb, node->ino, actiondfs_test_input_inode,
				     actiondfs_set_input_inode, node);
	else
		inode = iget_locked(sb, node->ino);
	if (!inode)
		return ERR_PTR(-ENOMEM);
	if (!(inode->i_state & I_NEW)) {
		if (input_child)
			actiondfs_free_node(node);
		return inode;
	}

	actiondfs_init_inode(inode, node);
	unlock_new_inode(inode);
	return inode;
}

static struct inode *actiondfs_prealloc_staged_inode(
	struct super_block *sb, struct actiondfs_node *parent,
	umode_t mode, const char *link_target,
	size_t link_target_len)
{
	struct actiondfs_node *node;
	struct inode *inode;

	node = actiondfs_alloc_staged_node(parent, mode,
					   link_target_len, 0);
	if (!node)
		return ERR_PTR(-ENOMEM);
	if (link_target) {
		node->link_target = kmemdup_nul(link_target, link_target_len,
					       GFP_KERNEL);
		if (!node->link_target) {
			actiondfs_free_node(node);
			return ERR_PTR(-ENOMEM);
		}
	}

	inode = new_inode(sb);
	if (!inode) {
		actiondfs_free_node(node);
		return ERR_PTR(-ENOMEM);
	}
	actiondfs_init_inode(inode, node);
	return inode;
}

static void actiondfs_insert_staged_inode(struct inode *inode,
					  struct dentry *real_dentry)
{
	struct actiondfs_node *node = inode->i_private;
	struct inode *real_inode = d_inode(real_dentry);
	umode_t permission_mask = S_ISDIR(node->mode) ? S_IALLUGO : 0777;

	node->ino = real_inode->i_ino & ~(1ULL << 63);
	node->mode = (node->mode & S_IFMT) |
		     (real_inode->i_mode & permission_mask);
	inode->i_ino = node->ino;
	inode->i_mode = node->mode;
	insert_inode_hash(inode);
	actiondfs_set_stage_dentry(node, real_dentry);
}

static int actiondfs_read_stage_symlink(struct dentry *dentry, char **target,
				       u64 *size)
{
	DEFINE_DELAYED_CALL(done);
	const char *link;
	size_t len;
	int err = 0;

	link = vfs_get_link(dentry, &done);
	if (IS_ERR(link)) {
		err = PTR_ERR(link);
		goto out;
	}
	len = strnlen(link, PATH_MAX);
	if (!len || len >= PATH_MAX) {
		err = -EINVAL;
		goto out;
	}
	*target = kmemdup_nul(link, len, GFP_KERNEL);
	if (!*target) {
		err = -ENOMEM;
		goto out;
	}
	*size = len;

out:
	do_delayed_call(&done);
	return err;
}

static struct inode *actiondfs_lookup_staged_inode(struct inode *dir,
						   struct dentry *dentry,
						   struct actiondfs_node *parent)
{
	struct actiondfs_sb_info *sbi = actiondfs_sbi(dir->i_sb);
	struct actiondfs_cached_child *input_child = NULL;
	struct actiondfs_cached_dir *input_cached = NULL;
	struct path parent_path;
	struct dentry *real_dentry;
	struct inode *real_inode;
	struct inode *inode;
	struct actiondfs_node *node;
	struct kstat stat;
	char *link_target = NULL;
	umode_t mode;
	u64 size = 0;
	bool merged_input = false;
	int err;

	if (!sbi->stage_path_valid)
		return NULL;
	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUPS);
	if (!READ_ONCE(parent->stage_dentry)) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUP_UNSTAGED_PARENT);
		return NULL;
	}
	err = actiondfs_stage_node_path(sbi, parent, &parent_path);
	if (err) {
		if (err == -ENOENT) {
			actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUP_NEGATIVE);
			return NULL;
		}
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUP_ERRORS);
		return ERR_PTR(err);
	}
	err = actiondfs_stage_lookup_child(&parent_path, dentry->d_name.name,
					   dentry->d_name.len, &real_dentry);
	if (err) {
		path_put(&parent_path);
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUP_ERRORS);
		return ERR_PTR(err);
	}
	if (!d_inode(real_dentry)) {
		actiondfs_stage_unlock_child(&parent_path, real_dentry);
		path_put(&parent_path);
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUP_NEGATIVE);
		return NULL;
	}

	real_inode = d_inode(real_dentry);
	mode = real_inode->i_mode;
	if (S_ISDIR(mode)) {
		mode = S_IFDIR | (mode & S_IALLUGO);
		input_child = actiondfs_find_cached_child(parent,
						 dentry->d_name.name,
						 dentry->d_name.len);
		if (input_child && S_ISDIR(input_child->mode)) {
			merged_input = true;
			err = actiondfs_get_cached_dir(sbi, input_child->hash,
						       input_child->size,
						       &input_cached);
			if (err) {
				actiondfs_stage_unlock_child(&parent_path, real_dentry);
				path_put(&parent_path);
				actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUP_ERRORS);
				return ERR_PTR(err);
			}
		}
	} else if (S_ISREG(mode)) {
		struct path real_path = {
			.mnt = parent_path.mnt,
			.dentry = real_dentry,
		};

		path_get(&real_path);
		mode = S_IFREG | (mode & 0777);
		err = vfs_getattr(&real_path, &stat, STATX_SIZE,
				  AT_STATX_SYNC_AS_STAT);
		path_put(&real_path);
		if (!err)
			size = stat.size;
	} else if (S_ISLNK(mode)) {
		err = actiondfs_read_stage_symlink(real_dentry, &link_target,
						    &size);
		if (err) {
			actiondfs_stage_unlock_child(&parent_path, real_dentry);
			path_put(&parent_path);
			actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUP_ERRORS);
			return ERR_PTR(err);
		}
		mode = S_IFLNK | 0777;
	} else {
		actiondfs_stage_unlock_child(&parent_path, real_dentry);
		path_put(&parent_path);
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUP_NEGATIVE);
		return NULL;
	}

	if (merged_input) {
		node = actiondfs_materialize_cached_child(parent, input_child);
		if (IS_ERR(node)) {
			err = PTR_ERR(node);
			node = NULL;
		} else {
			node->mode = mode;
		}
	} else {
		node = actiondfs_alloc_staged_node(parent, mode, size,
						   real_inode->i_ino);
		if (!node)
			err = -ENOMEM;
	}
	if (!node) {
		kfree(link_target);
		actiondfs_stage_unlock_child(&parent_path, real_dentry);
		path_put(&parent_path);
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUP_ERRORS);
		return ERR_PTR(err);
	}
	node->link_target = link_target;
	inode = actiondfs_iget(dir->i_sb, node);
	if (IS_ERR(inode)) {
		actiondfs_free_node(node);
		actiondfs_stage_unlock_child(&parent_path, real_dentry);
		path_put(&parent_path);
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUP_ERRORS);
	} else {
		if (inode->i_private != node) {
			if (!merged_input)
				actiondfs_free_node(node);
			node = inode->i_private;
		}
		if (S_ISDIR(mode)) {
			node->mode = mode;
			inode->i_mode = mode;
		}
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUP_HITS);
		actiondfs_set_stage_dentry(node, real_dentry);
		actiondfs_stage_unlock_child(&parent_path, real_dentry);
		path_put(&parent_path);
	}
	if (!IS_ERR(inode) && merged_input) {
		node->cached_dir = input_cached;
		smp_store_release(&node->loaded, true);
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUP_INPUT_DIR_MERGES);
	}
	return inode;
}

static struct dentry *actiondfs_lookup(struct inode *dir,
				       struct dentry *dentry,
				       unsigned int flags)
{
	struct actiondfs_node *parent = dir->i_private;
	struct inode *inode = NULL;
	int err;

	if (dentry->d_name.len > NAME_MAX)
		return ERR_PTR(-ENAMETOOLONG);

	err = actiondfs_ensure_loaded(dir->i_sb, parent);
	if (err)
		return ERR_PTR(err);

	actiondfs_stat_inc(ACTIONDFS_STAT_LOOKUPS);
	inode = actiondfs_lookup_staged_inode(dir, dentry, parent);
	if (IS_ERR(inode))
		return ERR_CAST(inode);
	if (inode) {
		actiondfs_stat_inc(ACTIONDFS_STAT_LOOKUP_HITS);
	} else {
		struct actiondfs_cached_child *record;

		record = actiondfs_find_cached_child(parent,
						     dentry->d_name.name,
						     dentry->d_name.len);
		if (record) {
			struct actiondfs_node *child;

			child = actiondfs_materialize_cached_child(parent, record);
			if (IS_ERR(child))
				return ERR_CAST(child);
			actiondfs_stat_inc(ACTIONDFS_STAT_LOOKUP_HITS);
			inode = actiondfs_iget(dir->i_sb, child);
			if (IS_ERR(inode)) {
				actiondfs_free_node(child);
				return ERR_CAST(inode);
			}
		} else {
			actiondfs_stat_inc(ACTIONDFS_STAT_LOOKUP_NEGATIVE);
		}
	}

	d_add(dentry, inode);
	return NULL;
}

static int actiondfs_create(struct mnt_idmap *idmap, struct inode *dir,
				    struct dentry *dentry, umode_t mode, bool excl)
{
	struct actiondfs_node *parent = dir->i_private;
	struct actiondfs_sb_info *sbi = actiondfs_sbi(dir->i_sb);
	struct inode *inode;
	struct path parent_path;
	struct dentry *real_dentry;
	int err;

	if (!sbi->stage_path_valid)
		return -EROFS;
	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_CREATE_CALLS);
	err = actiondfs_ensure_loaded(dir->i_sb, parent);
	if (err) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_CREATE_FAILURES);
		return err;
	}
	if (actiondfs_find_cached_child(parent, dentry->d_name.name,
						dentry->d_name.len)) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_CREATE_FAILURES);
		return -EROFS;
	}
	inode = actiondfs_prealloc_staged_inode(dir->i_sb, parent,
					       S_IFREG | (mode & 0777), NULL, 0);
	if (IS_ERR(inode)) {
		err = PTR_ERR(inode);
		goto out_fail;
	}

	err = actiondfs_ensure_stage_parent_path(sbi, parent, dentry->d_parent,
							 &parent_path);
	if (err)
		goto out_put_inode;
	err = mnt_want_write(parent_path.mnt);
	if (err)
		goto out_put_path;
	err = actiondfs_stage_lookup_child(&parent_path, dentry->d_name.name,
					   dentry->d_name.len, &real_dentry);
	if (err)
		goto out_drop_write;
	if (d_inode(real_dentry)) {
		err = -EEXIST;
		actiondfs_stage_unlock_child(&parent_path, real_dentry);
		goto out_drop_write;
	}
	err = vfs_create(mnt_idmap(parent_path.mnt),
			 d_inode(parent_path.dentry), real_dentry,
			 mode & 0777, excl);
	inode_unlock(d_inode(parent_path.dentry));
	if (err)
		dput(real_dentry);
	if (err)
		goto out_drop_write;
	actiondfs_insert_staged_inode(inode, real_dentry);
	dput(real_dentry);
	d_instantiate(dentry, inode);
	inode = NULL;
	actiondfs_note_stage_change(parent);
	err = 0;

out_drop_write:
	mnt_drop_write(parent_path.mnt);
out_put_path:
	path_put(&parent_path);
out_put_inode:
	if (inode)
		iput(inode);
out_fail:
	if (err)
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_CREATE_FAILURES);
	else
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_CREATE_SUCCESS);
	return err;
}

static int actiondfs_symlink(struct mnt_idmap *idmap, struct inode *dir,
			     struct dentry *dentry, const char *target)
{
	struct actiondfs_node *parent = dir->i_private;
	struct actiondfs_sb_info *sbi = actiondfs_sbi(dir->i_sb);
	struct inode *inode;
	struct path parent_path;
	struct dentry *real_dentry;
	size_t target_len;
	int err;

	if (!sbi->stage_path_valid)
		return -EROFS;
	target_len = strnlen(target, PATH_MAX);
	if (!target_len || target_len >= PATH_MAX)
		return -EINVAL;
	err = actiondfs_ensure_loaded(dir->i_sb, parent);
	if (err)
		return err;
	if (actiondfs_find_cached_child(parent, dentry->d_name.name,
						dentry->d_name.len))
		return -EROFS;
	inode = actiondfs_prealloc_staged_inode(dir->i_sb, parent,
					       S_IFLNK | 0777, target, target_len);
	if (IS_ERR(inode))
		return PTR_ERR(inode);

	err = actiondfs_ensure_stage_parent_path(sbi, parent, dentry->d_parent,
							 &parent_path);
	if (err)
		goto out_put_inode;
	err = mnt_want_write(parent_path.mnt);
	if (err)
		goto out_put_path;
	err = actiondfs_stage_lookup_child(&parent_path, dentry->d_name.name,
					   dentry->d_name.len, &real_dentry);
	if (err)
		goto out_drop_write;
	if (d_inode(real_dentry)) {
		err = -EEXIST;
		actiondfs_stage_unlock_child(&parent_path, real_dentry);
		goto out_drop_write;
	}
	err = vfs_symlink(mnt_idmap(parent_path.mnt),
			  d_inode(parent_path.dentry), real_dentry, target);
	inode_unlock(d_inode(parent_path.dentry));
	if (err) {
		dput(real_dentry);
		goto out_drop_write;
	}

	actiondfs_insert_staged_inode(inode, real_dentry);
	dput(real_dentry);
	d_instantiate(dentry, inode);
	inode = NULL;
	actiondfs_note_stage_change(parent);
	err = 0;

out_drop_write:
	mnt_drop_write(parent_path.mnt);
out_put_path:
	path_put(&parent_path);
out_put_inode:
	if (inode)
		iput(inode);
	return err;
}

static struct dentry *actiondfs_mkdir(struct mnt_idmap *idmap,
				      struct inode *dir,
				      struct dentry *dentry, umode_t mode)
{
	struct actiondfs_node *parent = dir->i_private;
	struct actiondfs_sb_info *sbi = actiondfs_sbi(dir->i_sb);
	struct inode *inode;
	struct path parent_path;
	struct dentry *real_dentry;
	struct dentry *created;
	int err;

	if (!sbi->stage_path_valid)
		return ERR_PTR(-EROFS);
	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_MKDIR_CALLS);
	err = actiondfs_ensure_loaded(dir->i_sb, parent);
	if (err) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_MKDIR_FAILURES);
		return ERR_PTR(err);
	}
	if (actiondfs_find_cached_child(parent, dentry->d_name.name,
						dentry->d_name.len)) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_MKDIR_FAILURES);
		return ERR_PTR(-EROFS);
	}
	inode = actiondfs_prealloc_staged_inode(dir->i_sb, parent,
					       S_IFDIR | (mode & S_IALLUGO), NULL, 0);
	if (IS_ERR(inode)) {
		err = PTR_ERR(inode);
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_MKDIR_FAILURES);
		return ERR_PTR(err);
	}

	err = actiondfs_ensure_stage_parent_path(sbi, parent, dentry->d_parent,
							 &parent_path);
	if (err)
		goto out_put_inode;
	err = mnt_want_write(parent_path.mnt);
	if (err)
		goto out_put_path;
	err = actiondfs_stage_lookup_child(&parent_path, dentry->d_name.name,
					   dentry->d_name.len, &real_dentry);
	if (err)
		goto out_drop_write;
	created = vfs_mkdir(mnt_idmap(parent_path.mnt),
			    d_inode(parent_path.dentry), real_dentry,
			    mode & S_IALLUGO);
	if (IS_ERR(created)) {
		err = PTR_ERR(created);
		inode_unlock(d_inode(parent_path.dentry));
	} else {
		err = 0;
		inode_unlock(d_inode(parent_path.dentry));
	}
	if (err)
		goto out_drop_write;
	actiondfs_insert_staged_inode(inode, created);
	dput(created);
	inc_nlink(dir);
	d_instantiate(dentry, inode);
	inode = NULL;
	actiondfs_note_stage_change(parent);

out_drop_write:
	mnt_drop_write(parent_path.mnt);
out_put_path:
	path_put(&parent_path);
out_put_inode:
	if (inode)
		iput(inode);
	if (err)
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_MKDIR_FAILURES);
	else
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_MKDIR_SUCCESS);
	return ERR_PTR(err);
}

static int actiondfs_unlink(struct inode *dir, struct dentry *dentry)
{
	struct inode *inode = d_inode(dentry);
	struct actiondfs_node *node = inode->i_private;
	struct actiondfs_node *parent = dir->i_private;
	struct actiondfs_sb_info *sbi = actiondfs_sbi(dir->i_sb);
	struct path parent_path;
	struct dentry *real_dentry;
	int err;

	if (node->origin != ACTIONDFS_NODE_STAGED)
		return -EROFS;
	if (S_ISDIR(node->mode))
		return -EISDIR;

	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_UNLINK_CALLS);
	err = actiondfs_stage_node_path(sbi, parent, &parent_path);
	if (err) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_UNLINK_FAILURES);
		return err;
	}
	err = mnt_want_write(parent_path.mnt);
	if (err)
		goto out_put_path;
	err = actiondfs_stage_lookup_child(&parent_path, dentry->d_name.name,
					   dentry->d_name.len, &real_dentry);
	if (err)
		goto out_drop_write;
	if (!d_inode(real_dentry)) {
		err = -ENOENT;
	} else {
		err = vfs_unlink(mnt_idmap(parent_path.mnt),
				 d_inode(parent_path.dentry), real_dentry,
				 NULL);
	}
	actiondfs_stage_unlock_child(&parent_path, real_dentry);
	if (!err) {
		clear_nlink(inode);
		actiondfs_note_stage_change(parent);
	}
out_drop_write:
	mnt_drop_write(parent_path.mnt);
out_put_path:
	path_put(&parent_path);
	if (err)
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_UNLINK_FAILURES);
	else
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_UNLINK_SUCCESS);
	return err;
}

static int actiondfs_rmdir(struct inode *dir, struct dentry *dentry)
{
	struct inode *inode = d_inode(dentry);
	struct actiondfs_node *node = inode->i_private;
	struct actiondfs_node *parent = dir->i_private;
	struct actiondfs_sb_info *sbi = actiondfs_sbi(dir->i_sb);
	struct path parent_path;
	struct dentry *real_dentry;
	int err;

	if (node->origin != ACTIONDFS_NODE_STAGED)
		return -EROFS;
	if (!S_ISDIR(node->mode))
		return -ENOTDIR;
	if (node->cached_dir)
		return -EROFS;

	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_RMDIR_CALLS);
	err = actiondfs_stage_node_path(sbi, parent, &parent_path);
	if (err) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_RMDIR_FAILURES);
		return err;
	}
	err = mnt_want_write(parent_path.mnt);
	if (err)
		goto out_put_path;
	err = actiondfs_stage_lookup_child(&parent_path, dentry->d_name.name,
					   dentry->d_name.len, &real_dentry);
	if (err)
		goto out_drop_write;
	if (!d_inode(real_dentry)) {
		err = -ENOENT;
	} else {
		err = vfs_rmdir(mnt_idmap(parent_path.mnt),
				d_inode(parent_path.dentry), real_dentry);
	}
	actiondfs_stage_unlock_child(&parent_path, real_dentry);
	if (!err) {
		clear_nlink(inode);
		drop_nlink(dir);
		actiondfs_note_stage_change(parent);
	}
out_drop_write:
	mnt_drop_write(parent_path.mnt);
out_put_path:
	path_put(&parent_path);
	if (err)
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_RMDIR_FAILURES);
	else
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_RMDIR_SUCCESS);
	return err;
}

static int actiondfs_rename(struct mnt_idmap *idmap, struct inode *old_dir,
			    struct dentry *old_dentry, struct inode *new_dir,
			    struct dentry *new_dentry, unsigned int flags)
{
	struct actiondfs_sb_info *sbi = actiondfs_sbi(old_dir->i_sb);
	struct actiondfs_node *old_parent = old_dir->i_private;
	struct actiondfs_node *new_parent = new_dir->i_private;
	struct actiondfs_node *old_node = d_inode(old_dentry)->i_private;
	struct actiondfs_node *new_node = d_inode(new_dentry) ?
		d_inode(new_dentry)->i_private : NULL;
	struct path old_parent_path;
	struct path new_parent_path;
	struct dentry *real_old = NULL;
	struct dentry *real_new = NULL;
	struct dentry *trap;
	struct renamedata rd = {};
	struct qstr old_name = QSTR_LEN(old_dentry->d_name.name,
					old_dentry->d_name.len);
	struct qstr new_name = QSTR_LEN(new_dentry->d_name.name,
					new_dentry->d_name.len);
	int err;

	if (flags & ~RENAME_NOREPLACE)
		return -EINVAL;
	if (old_node->origin != ACTIONDFS_NODE_STAGED)
		return -EROFS;
	if (new_node && new_node->origin != ACTIONDFS_NODE_STAGED)
		return -EROFS;
	if ((S_ISDIR(old_node->mode) && old_node->cached_dir) ||
	    (new_node && S_ISDIR(new_node->mode) && new_node->cached_dir))
		return -EROFS;

	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_RENAME_CALLS);
	err = actiondfs_stage_node_path(sbi, old_parent, &old_parent_path);
	if (err)
		goto out_done;
	err = actiondfs_ensure_stage_parent_path(sbi, new_parent,
						 new_dentry->d_parent,
						 &new_parent_path);
	if (err)
		goto out_put_old_path;
	if (old_parent_path.mnt != new_parent_path.mnt) {
		err = -EXDEV;
		goto out_put_new_path;
	}
	err = mnt_want_write(old_parent_path.mnt);
	if (err)
		goto out_put_new_path;

	trap = lock_rename(new_parent_path.dentry, old_parent_path.dentry);
	if (IS_ERR(trap)) {
		err = PTR_ERR(trap);
		goto out_drop_write;
	}
	real_old = lookup_one(&nop_mnt_idmap, &old_name, old_parent_path.dentry);
	if (IS_ERR(real_old)) {
		err = PTR_ERR(real_old);
		real_old = NULL;
		goto out_unlock;
	}
	real_new = lookup_one(&nop_mnt_idmap, &new_name, new_parent_path.dentry);
	if (IS_ERR(real_new)) {
		err = PTR_ERR(real_new);
		real_new = NULL;
		goto out_unlock;
	}
	if (!d_inode(real_old)) {
		err = -ENOENT;
		goto out_unlock;
	}
	if ((flags & RENAME_NOREPLACE) && d_inode(real_new)) {
		err = -EEXIST;
		goto out_unlock;
	}
	if (real_old == trap) {
		err = -EINVAL;
		goto out_unlock;
	}
	if (real_new == trap) {
		err = -ENOTEMPTY;
		goto out_unlock;
	}

	rd.mnt_idmap = mnt_idmap(old_parent_path.mnt);
	rd.old_parent = old_parent_path.dentry;
	rd.old_dentry = real_old;
	rd.new_parent = new_parent_path.dentry;
	rd.new_dentry = real_new;
	rd.flags = flags;
	err = vfs_rename(&rd);
	if (!err) {
		if (new_node)
			clear_nlink(d_inode(new_dentry));
		if (S_ISDIR(old_node->mode)) {
			if (old_dir != new_dir) {
				drop_nlink(old_dir);
				if (!new_node)
					inc_nlink(new_dir);
			} else if (new_node) {
				drop_nlink(new_dir);
			}
		}
		old_node->parent = new_parent;
		actiondfs_note_stage_change(old_parent);
		if (new_parent != old_parent)
			actiondfs_note_stage_change(new_parent);
	}

out_unlock:
	if (real_new)
		dput(real_new);
	if (real_old)
		dput(real_old);
	unlock_rename(new_parent_path.dentry, old_parent_path.dentry);
out_drop_write:
	mnt_drop_write(old_parent_path.mnt);
out_put_new_path:
	path_put(&new_parent_path);
out_put_old_path:
	path_put(&old_parent_path);
out_done:
	if (err)
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_RENAME_FAILURES);
	else
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_RENAME_SUCCESS);
	return err;
}

static int actiondfs_open(struct inode *inode, struct file *file)
{
	struct actiondfs_node *node = inode->i_private;
	struct actiondfs_sb_info *sbi = actiondfs_sbi(inode->i_sb);
	struct file *backing_file;
	int err;

	if (node->origin != ACTIONDFS_NODE_STAGED &&
	    (file->f_mode & FMODE_WRITE))
		return -EROFS;
	if (node->origin == ACTIONDFS_NODE_INPUT) {
		if (!node->size && actiondfs_is_empty_sha256(node->hash))
			return 0;
		err = actiondfs_valid_hash(node->hash);
		if (err)
			return err;
		actiondfs_stat_inc(ACTIONDFS_STAT_NODE_BLOB_CACHE_MISSES);
		backing_file = actiondfs_open_backing_cas_blob(
			sbi, node->hash, file_user_path(file), node->size);
	} else {
		backing_file = actiondfs_open_staged_backing(
			sbi, file, actiondfs_staged_backing_flags(file));
	}
	if (IS_ERR(backing_file))
		return PTR_ERR(backing_file);
	file->private_data = backing_file;
	return 0;
}

static int actiondfs_release(struct inode *inode, struct file *file)
{
	struct file *backing_file = file->private_data;

	if (!backing_file)
		return 0;
	fput(backing_file);
	file->private_data = NULL;
	return 0;
}

static int actiondfs_fsync(struct file *file, loff_t start, loff_t end,
			   int datasync)
{
	struct inode *inode = file_inode(file);
	struct actiondfs_node *node = inode->i_private;
	struct file *backing_file;
	struct path real_path;
	int err;

	if (S_ISDIR(inode->i_mode)) {
		err = actiondfs_stage_node_path(actiondfs_sbi(inode->i_sb), node,
					       &real_path);
		if (err == -ENOENT || err == -EROFS)
			return 0;
		if (err)
			return err;
		backing_file = dentry_open(&real_path, O_RDONLY | O_DIRECTORY,
					   current_cred());
		path_put(&real_path);
		if (IS_ERR(backing_file))
			return PTR_ERR(backing_file);
	} else {
		if (node->origin != ACTIONDFS_NODE_STAGED)
			return 0;
		backing_file = file->private_data;
		if (!backing_file)
			return -EBADF;
		get_file(backing_file);
	}

	err = vfs_fsync_range(backing_file, start, end, datasync);
	fput(backing_file);
	return err;
}

static int actiondfs_setattr(struct mnt_idmap *idmap, struct dentry *dentry,
			     struct iattr *attr)
{
	struct inode *inode = d_inode(dentry);
	struct actiondfs_node *node = inode->i_private;
	struct path real_path;
	struct iattr real_attr;
	bool changing_size = attr->ia_valid & ATTR_SIZE;
	int err;

	if (node->origin != ACTIONDFS_NODE_STAGED)
		return -EROFS;
	if (changing_size)
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_SETATTR_SIZE_CALLS);

	err = setattr_prepare(idmap, dentry, attr);
	if (err)
		goto out;
	err = actiondfs_stage_node_path(actiondfs_sbi(inode->i_sb), node,
				       &real_path);
	if (err)
		goto out;
	err = mnt_want_write(real_path.mnt);
	if (err) {
		path_put(&real_path);
		goto out;
	}

	real_attr = *attr;
	if (real_attr.ia_valid & ATTR_FILE) {
		if (!real_attr.ia_file || !real_attr.ia_file->private_data) {
			err = -EBADF;
			goto out_drop_write;
		}
		real_attr.ia_file = real_attr.ia_file->private_data;
	}

	inode_lock(d_inode(real_path.dentry));
	err = notify_change(mnt_idmap(real_path.mnt), real_path.dentry,
			    &real_attr, NULL);
	inode_unlock(d_inode(real_path.dentry));
	if (!err) {
		if (changing_size)
			actiondfs_sync_staged_inode(inode,
						    d_inode(real_path.dentry));
		setattr_copy(idmap, inode, attr);
		if (attr->ia_valid & ATTR_MODE)
			node->mode = inode->i_mode;
		mark_inode_dirty(inode);
	}

out_drop_write:
	mnt_drop_write(real_path.mnt);
	path_put(&real_path);
out:
	if (changing_size) {
		if (err)
			actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_SETATTR_SIZE_FAILURES);
		else
			actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_SETATTR_SIZE_SUCCESS);
	}
	return err;
}

struct actiondfs_dir_file {
	bool stage_loaded;
	bool stage_eof;
	u64 stage_generation;
	loff_t stage_logical_pos;
	struct file *stage_file;
};

struct actiondfs_stage_emit_ctx {
	struct dir_context ctx;
	struct dir_context *output;
	struct actiondfs_node *dir;
	struct actiondfs_dir_file *dir_file;
	loff_t base;
	bool output_full;
};

static bool actiondfs_stage_emit_filldir(struct dir_context *ctx,
					 const char *name,
					 int namelen, loff_t offset,
					 u64 ino, unsigned int d_type)
{
	struct actiondfs_stage_emit_ctx *stage_ctx =
		container_of(ctx, struct actiondfs_stage_emit_ctx, ctx);
	struct actiondfs_dir_file *dir_file = stage_ctx->dir_file;
	loff_t requested_pos = stage_ctx->output->pos - stage_ctx->base;

	if ((namelen == 1 && name[0] == '.') ||
	    (namelen == 2 && name[0] == '.' && name[1] == '.'))
		return true;

	if (actiondfs_find_cached_child(stage_ctx->dir, name, namelen))
		return true;

	if (dir_file->stage_logical_pos < requested_pos) {
		dir_file->stage_logical_pos++;
		actiondfs_stat_inc(
			ACTIONDFS_STAT_READDIR_SKIPPED_ENTRIES_AVOIDED);
		return true;
	}
	if (!dir_emit(stage_ctx->output, name, namelen,
		      ino & ~(1ULL << 63), d_type)) {
		stage_ctx->output_full = true;
		return false;
	}
	dir_file->stage_logical_pos++;
	stage_ctx->output->pos = stage_ctx->base +
				 dir_file->stage_logical_pos;
	actiondfs_stat_inc(ACTIONDFS_STAT_READDIR_ENTRIES);
	return true;
}

static void actiondfs_reset_stage_file(struct actiondfs_dir_file *dir_file)
{
	if (dir_file->stage_file)
		fput(dir_file->stage_file);
	dir_file->stage_file = NULL;
	dir_file->stage_logical_pos = 0;
	dir_file->stage_eof = false;
	dir_file->stage_loaded = false;
}

static void actiondfs_free_dir_file(struct actiondfs_dir_file *dir_file)
{
	if (!dir_file)
		return;
	actiondfs_reset_stage_file(dir_file);
	kfree(dir_file);
}

static int actiondfs_open_stage_file(struct inode *inode,
				    struct actiondfs_node *dir,
				    struct actiondfs_dir_file *dir_file)
{
	struct actiondfs_sb_info *sbi = actiondfs_sbi(inode->i_sb);
	struct path real_path;
	struct file *file;
	u64 generation = atomic64_read(&dir->stage_generation);
	int err;

	if (dir_file->stage_loaded &&
	    dir_file->stage_generation == generation)
		return 0;
	if (dir_file->stage_loaded)
		actiondfs_reset_stage_file(dir_file);
	dir_file->stage_loaded = true;
	dir_file->stage_generation = generation;
	if (!sbi->stage_path_valid) {
		dir_file->stage_eof = true;
		return 0;
	}

	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_READDIR_CALLS);
	err = actiondfs_stage_node_path(sbi, dir, &real_path);
	if (err == -ENOENT) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_READDIR_MISSES);
		dir_file->stage_eof = true;
		return 0;
	}
	if (err) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_READDIR_ERRORS);
		return err;
	}
	file = dentry_open(&real_path, O_RDONLY | O_DIRECTORY, current_cred());
	path_put(&real_path);
	if (IS_ERR(file)) {
		err = PTR_ERR(file);
		if (err == -ENOENT) {
			actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_READDIR_MISSES);
			dir_file->stage_eof = true;
			return 0;
		}
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_READDIR_ERRORS);
		return err;
	}
	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_READDIR_HITS);
	dir_file->stage_file = file;
	return 0;
}

static int actiondfs_emit_stage_entries(struct inode *inode,
					struct actiondfs_node *dir,
					struct actiondfs_dir_file *dir_file,
					struct dir_context *ctx, loff_t base)
{
	struct actiondfs_stage_emit_ctx stage_ctx;
	loff_t requested_pos = ctx->pos - base;
	int err;

	err = actiondfs_open_stage_file(inode, dir, dir_file);
	if (err || !dir_file->stage_file)
		return err;
	if (requested_pos < dir_file->stage_logical_pos) {
		loff_t pos;

		pos = vfs_llseek(dir_file->stage_file, 0, SEEK_SET);
		if (pos < 0)
			return pos;
		dir_file->stage_logical_pos = 0;
		dir_file->stage_eof = false;
	}
	if (dir_file->stage_eof)
		return 0;

	stage_ctx = (struct actiondfs_stage_emit_ctx){
		.ctx = {
			.actor = actiondfs_stage_emit_filldir,
		},
		.output = ctx,
		.dir = dir,
		.dir_file = dir_file,
		.base = base,
	};
	err = iterate_dir(dir_file->stage_file, &stage_ctx.ctx);
	if (err) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_READDIR_ERRORS);
		return err;
	}
	if (!stage_ctx.output_full)
		dir_file->stage_eof = true;
	return 0;
}

static int actiondfs_dir_open(struct inode *inode, struct file *file)
{
	struct actiondfs_dir_file *dir_file;

	dir_file = kzalloc(sizeof(*dir_file), GFP_KERNEL);
	if (!dir_file)
		return -ENOMEM;
	file->private_data = dir_file;
	return 0;
}

static int actiondfs_dir_release(struct inode *inode, struct file *file)
{
	actiondfs_free_dir_file(file->private_data);
	file->private_data = NULL;
	return 0;
}

static int actiondfs_iterate_shared(struct file *file, struct dir_context *ctx)
{
	struct inode *inode = file_inode(file);
	struct actiondfs_node *dir = inode->i_private;
	struct actiondfs_dir_file *dir_file = file->private_data;
	size_t i;
	loff_t base = 2;
	int err;

	if (!ctx->pos && dir_file->stage_loaded)
		actiondfs_reset_stage_file(dir_file);

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

			if (!dir_emit(ctx, child->name, child->name_len,
				      actiondfs_input_child_ino(dir, child->name,
							       child->name_len,
							       false),
				      DT_REG))
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

			if (!dir_emit(ctx, child->name, child->name_len,
				      actiondfs_input_child_ino(dir, child->name,
							       child->name_len,
							       true),
				      DT_DIR))
				return 0;
			actiondfs_stat_inc(ACTIONDFS_STAT_READDIR_ENTRIES);
			ctx->pos = pos + 1;
		}
		base += cached->dir_count;

		i = actiondfs_readdir_start_index_counted(ctx->pos, base,
							  cached->symlink_count);
		for (; i < cached->symlink_count; i++) {
			struct actiondfs_cached_child *child =
				&cached->symlink_children[i];
			loff_t pos = base + i;

			if (!dir_emit(ctx, child->name, child->name_len,
				      actiondfs_input_child_ino(dir, child->name,
							       child->name_len,
							       false),
				      DT_LNK))
				return 0;
			actiondfs_stat_inc(ACTIONDFS_STAT_READDIR_ENTRIES);
			ctx->pos = pos + 1;
		}
		base += cached->symlink_count;
	}

	return actiondfs_emit_stage_entries(inode, dir, dir_file, ctx, base);
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

static int actiondfs_dir_getattr(struct mnt_idmap *idmap,
				 const struct path *path,
				 struct kstat *stat,
				 u32 request_mask,
				 unsigned int query_flags)
{
	struct inode *inode = d_inode(path->dentry);
	struct actiondfs_node *node = inode->i_private;
	struct actiondfs_cached_dir *cached;
	struct dentry *stage_dentry;
	struct inode *stage_inode;
	size_t input_dir_count;
	unsigned int backing_nlink = 0;
	int err;

	err = actiondfs_ensure_loaded(inode->i_sb, node);
	if (err)
		return err;
	err = simple_getattr(idmap, path, stat, request_mask, query_flags);
	if (err)
		return err;

	cached = node->cached_dir;
	stage_dentry = READ_ONCE(node->stage_dentry);
	if (stage_dentry) {
		stage_inode = d_inode(stage_dentry);
		if (stage_inode && S_ISDIR(stage_inode->i_mode))
			backing_nlink = READ_ONCE(stage_inode->i_nlink);
		else
			stage_dentry = NULL;
	}
	if (!cached) {
		if (stage_dentry)
			stat->nlink = backing_nlink;
		return 0;
	}

	if (cached->dir_count > UINT_MAX - 2) {
		stat->nlink = 1;
		return 0;
	}
	input_dir_count = cached->dir_count;
	if (!stage_dentry || backing_nlink == 2)
		stat->nlink = 2 + input_dir_count;
	else if (!input_dir_count)
		stat->nlink = backing_nlink;
	else
		stat->nlink = 1;
	return 0;
}

static const struct inode_operations actiondfs_file_iops = {
	.getattr = simple_getattr,
	.setattr = actiondfs_setattr,
};

static const struct inode_operations actiondfs_symlink_iops = {
	.get_link = simple_get_link,
	.getattr = simple_getattr,
	.setattr = actiondfs_setattr,
};

static const struct file_operations actiondfs_file_fops = {
	.open = actiondfs_open,
	.release = actiondfs_release,
	.fsync = actiondfs_fsync,
	.llseek = generic_file_llseek,
	.read_iter = actiondfs_read_iter,
	.write_iter = actiondfs_write_iter,
	.copy_file_range = actiondfs_copy_file_range,
	.mmap = actiondfs_mmap,
	.splice_read = actiondfs_splice_read,
};

static const struct inode_operations actiondfs_dir_iops = {
	.lookup = actiondfs_lookup,
	.create = actiondfs_create,
	.symlink = actiondfs_symlink,
	.mkdir = actiondfs_mkdir,
	.unlink = actiondfs_unlink,
	.rmdir = actiondfs_rmdir,
	.rename = actiondfs_rename,
	.getattr = actiondfs_dir_getattr,
	.setattr = actiondfs_setattr,
};

static const struct file_operations actiondfs_dir_fops = {
	.open = actiondfs_dir_open,
	.release = actiondfs_dir_release,
	.fsync = actiondfs_fsync,
	.llseek = generic_file_llseek,
	.read = generic_read_dir,
	.iterate_shared = actiondfs_iterate_shared,
};

static void actiondfs_evict_inode(struct inode *inode)
{
	struct actiondfs_node *node = inode->i_private;
	struct actiondfs_sb_info *sbi = actiondfs_sbi(inode->i_sb);

	truncate_inode_pages_final(&inode->i_data);
	clear_inode(inode);
	if (!node)
		return;
	if (sbi && node == sbi->root) {
		inode->i_private = NULL;
		return;
	}
	if (node->stage_dentry) {
		dput(node->stage_dentry);
		node->stage_dentry = NULL;
	}
}

static void actiondfs_free_inode(struct inode *inode)
{
	struct actiondfs_node *node = inode->i_private;

	if (node) {
		WARN_ON_ONCE(node->stage_dentry);
		actiondfs_free_node(node);
	}
	free_inode_nonrcu(inode);
}

static void actiondfs_put_super(struct super_block *sb)
{
	struct actiondfs_sb_info *sbi = actiondfs_sbi(sb);

	if (!sbi)
		return;
	actiondfs_free_node(sbi->root);
	if (sbi->cas_path.dentry)
		path_put(&sbi->cas_path);
	if (sbi->stage_path_valid)
		path_put(&sbi->stage_path);
	kfree(sbi);
	sb->s_fs_info = NULL;
}

static const struct super_operations actiondfs_super_ops = {
	.statfs = simple_statfs,
	.put_super = actiondfs_put_super,
	.evict_inode = actiondfs_evict_inode,
	.free_inode = actiondfs_free_inode,
};

struct actiondfs_mount_context {
	char *options;
};

static int actiondfs_fill_super(struct super_block *sb, struct fs_context *fc)
{
	struct actiondfs_mount_context *ctx = fc->fs_private;
	struct actiondfs_mount_options opts = {
		.root_size = ACTIONDFS_UNKNOWN_SIZE,
	};
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
	sb->s_flags |= SB_NOATIME;
	sb->s_op = &actiondfs_super_ops;
	sb->s_time_gran = 1;

	sbi->root = actiondfs_alloc_node(S_IFDIR | ACTIONDFS_DIR_MODE);
	if (!sbi->root) {
		err = -ENOMEM;
		goto fail;
	}
	sbi->root->ino = 1;

	err = actiondfs_parse_options(&opts, ctx ? ctx->options : NULL);
	if (err)
		goto fail;
	err = kern_path(opts.cas_root, LOOKUP_FOLLOW | LOOKUP_DIRECTORY,
			&sbi->cas_path);
	if (err)
		goto fail;
	if (opts.stage_root) {
		err = kern_path(opts.stage_root, LOOKUP_FOLLOW | LOOKUP_DIRECTORY,
				&sbi->stage_path);
		if (err)
			goto fail;
		sbi->stage_path_valid = true;
		actiondfs_set_stage_dentry(sbi->root, sbi->stage_path.dentry);
	} else {
		sb->s_flags |= SB_RDONLY;
	}
	memcpy(sbi->root->hash, opts.root_hash, 64);
	sbi->root->hash[64] = '\0';
	sbi->root->size = opts.root_size;
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
	actiondfs_free_mount_options(&opts);
	return 0;

fail:
	actiondfs_free_mount_options(&opts);
	actiondfs_put_super(sb);
	return err;
}

static int actiondfs_get_tree(struct fs_context *fc)
{
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
	.name = ACTIONDFS_FS_NAME,
	.init_fs_context = actiondfs_init_fs_context,
	.kill_sb = kill_anon_super,
};

#if ACTIONDFS_ENABLE_STATS
static int actiondfs_stats_show(struct seq_file *m, void *v)
{
	size_t i;

	for (i = 0; i < ACTIONDFS_STAT_COUNT; i++)
		seq_printf(m, "%s %lld\n", actiondfs_stat_names[i],
			   atomic64_read(&actiondfs_stats[i]));
	return 0;
}
#endif

static int __init actiondfs_init(void)
{
	int err;

	actiondfs_blob_path_cache_release_wq = alloc_workqueue(
		ACTIONDFS_FS_NAME "-blob-cache", WQ_UNBOUND | WQ_MEM_RECLAIM, 0);
	if (!actiondfs_blob_path_cache_release_wq)
		return -ENOMEM;

	err = register_filesystem(&actiondfs_fs_type);
	if (err)
		goto fail_workqueue;
#if ACTIONDFS_ENABLE_STATS
	if (!proc_create_single(ACTIONDFS_PROC_STATS, 0444, NULL,
				actiondfs_stats_show)) {
		err = -ENOMEM;
		goto fail_filesystem;
	}
#endif
	return 0;

#if ACTIONDFS_ENABLE_STATS
fail_filesystem:
	unregister_filesystem(&actiondfs_fs_type);
#endif
fail_workqueue:
	destroy_workqueue(actiondfs_blob_path_cache_release_wq);
	return err;
}

static void __exit actiondfs_exit(void)
{
#if ACTIONDFS_ENABLE_STATS
	remove_proc_entry(ACTIONDFS_PROC_STATS, NULL);
#endif
	unregister_filesystem(&actiondfs_fs_type);
	actiondfs_destroy_blob_path_cache();
	rcu_barrier();
	destroy_workqueue(actiondfs_blob_path_cache_release_wq);
	actiondfs_destroy_dir_cache();
}

module_init(actiondfs_init);
module_exit(actiondfs_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("actiond manifest filesystem");
