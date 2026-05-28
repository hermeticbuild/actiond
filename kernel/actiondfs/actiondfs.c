// SPDX-License-Identifier: GPL-2.0-only
/*
 * actiondfs - read-only action input manifest filesystem for actiond.
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
#define ACTIONDFS_EMPTY_SHA256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
#define ACTIONDFS_UNKNOWN_SIZE (~(u64)0)

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
	u64 size;
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

enum actiondfs_node_origin {
	ACTIONDFS_NODE_INPUT,
	ACTIONDFS_NODE_STAGED,
};

struct actiondfs_node {
	char *name;
	size_t name_len;
	bool name_borrowed;
	enum actiondfs_node_origin origin;
	char *stage_rel;
	u64 ino;
	umode_t mode;
	u64 size;
	char hash[65];
	struct file *blob_file;
	struct mutex blob_lock;
	bool loaded;
	bool stage_children_known_empty;
	bool stage_dir_ready;
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

struct actiondfs_file_ctx {
	struct file *staged_file;
};

struct actiondfs_sb_info {
	char *cas_root;
	char *root_hash;
	u64 root_size;
	char *stage_root;
	struct path cas_path;
	struct path stage_path;
	bool cas_path_valid;
	bool stage_path_valid;
	bool staged_writes;
	struct actiondfs_node *root;
	atomic64_t next_ino;
	struct mutex load_lock;
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
	ACTIONDFS_STAT_BLOB_OPEN_BACKING_TOTAL_NS,
	ACTIONDFS_STAT_BLOB_OPEN_BACKING_PATH_NS,
	ACTIONDFS_STAT_BLOB_OPEN_BACKING_FILE_NS,
	ACTIONDFS_STAT_BLOB_OPEN_REAL_TOTAL_NS,
	ACTIONDFS_STAT_BLOB_OPEN_REAL_PATH_NS,
	ACTIONDFS_STAT_BLOB_OPEN_REAL_FILE_NS,
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
	ACTIONDFS_STAT_STAGE_PARENT_PATH_LOOKUPS,
	ACTIONDFS_STAT_STAGE_PARENT_PATH_ERRORS,
	ACTIONDFS_STAT_STAGE_CHILD_LOOKUPS,
	ACTIONDFS_STAT_STAGE_CHILD_LOOKUP_HITS,
	ACTIONDFS_STAT_STAGE_CHILD_LOOKUP_NEGATIVE,
	ACTIONDFS_STAT_STAGE_CHILD_LOOKUP_ERRORS,
	ACTIONDFS_STAT_STAGE_ENSURE_DIR_CALLS,
	ACTIONDFS_STAT_STAGE_ENSURE_DIR_COMPONENTS,
	ACTIONDFS_STAT_STAGE_ENSURE_DIR_EXISTING,
	ACTIONDFS_STAT_STAGE_ENSURE_DIR_CREATED,
	ACTIONDFS_STAT_STAGE_ENSURE_DIR_ERRORS,
	ACTIONDFS_STAT_STAGE_ENSURE_DIR_READY_HITS,
	ACTIONDFS_STAT_STAGE_INODE_LOOKUPS,
	ACTIONDFS_STAT_STAGE_INODE_LOOKUP_SKIPPED_EMPTY_DIR,
	ACTIONDFS_STAT_STAGE_INODE_LOOKUP_HITS,
	ACTIONDFS_STAT_STAGE_INODE_LOOKUP_NEGATIVE,
	ACTIONDFS_STAT_STAGE_INODE_LOOKUP_ERRORS,
	ACTIONDFS_STAT_STAGE_INODE_LOOKUP_INPUT_DIR_MERGES,
	ACTIONDFS_STAT_STAGE_BACKING_OPEN_ATTEMPTS,
	ACTIONDFS_STAT_STAGE_BACKING_OPEN_FAILURES,
	ACTIONDFS_STAT_STAGE_BACKING_OPEN_CACHED_HITS,
	ACTIONDFS_STAT_STAGE_BACKING_OPEN_CACHED_MISSES,
	ACTIONDFS_STAT_STAGE_BACKING_OPEN_READ_CALLS,
	ACTIONDFS_STAT_STAGE_BACKING_OPEN_WRITE_CALLS,
	ACTIONDFS_STAT_STAGE_BACKING_OPEN_SPLICE_READ_CALLS,
	ACTIONDFS_STAT_STAGE_BACKING_OPEN_MMAP_CALLS,
	ACTIONDFS_STAT_STAGE_BACKING_OPEN_TOTAL_NS,
	ACTIONDFS_STAT_STAGE_BACKING_OPEN_LOOKUP_NS,
	ACTIONDFS_STAT_STAGE_BACKING_OPEN_FILE_NS,
	ACTIONDFS_STAT_STAGE_REAL_OPEN_ATTEMPTS,
	ACTIONDFS_STAT_STAGE_REAL_OPEN_FAILURES,
	ACTIONDFS_STAT_STAGE_REAL_OPEN_COPY_IN_CALLS,
	ACTIONDFS_STAT_STAGE_REAL_OPEN_COPY_OUT_CALLS,
	ACTIONDFS_STAT_STAGE_REAL_OPEN_NS,
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
	[ACTIONDFS_STAT_BLOB_OPEN_BACKING_TOTAL_NS] = "blob_open_backing_total_ns",
	[ACTIONDFS_STAT_BLOB_OPEN_BACKING_PATH_NS] = "blob_open_backing_path_ns",
	[ACTIONDFS_STAT_BLOB_OPEN_BACKING_FILE_NS] = "blob_open_backing_file_ns",
	[ACTIONDFS_STAT_BLOB_OPEN_REAL_TOTAL_NS] = "blob_open_real_total_ns",
	[ACTIONDFS_STAT_BLOB_OPEN_REAL_PATH_NS] = "blob_open_real_path_ns",
	[ACTIONDFS_STAT_BLOB_OPEN_REAL_FILE_NS] = "blob_open_real_file_ns",
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
	[ACTIONDFS_STAT_STAGE_PARENT_PATH_LOOKUPS] = "stage_parent_path_lookups",
	[ACTIONDFS_STAT_STAGE_PARENT_PATH_ERRORS] = "stage_parent_path_errors",
	[ACTIONDFS_STAT_STAGE_CHILD_LOOKUPS] = "stage_child_lookups",
	[ACTIONDFS_STAT_STAGE_CHILD_LOOKUP_HITS] = "stage_child_lookup_hits",
	[ACTIONDFS_STAT_STAGE_CHILD_LOOKUP_NEGATIVE] = "stage_child_lookup_negative",
	[ACTIONDFS_STAT_STAGE_CHILD_LOOKUP_ERRORS] = "stage_child_lookup_errors",
	[ACTIONDFS_STAT_STAGE_ENSURE_DIR_CALLS] = "stage_ensure_dir_calls",
	[ACTIONDFS_STAT_STAGE_ENSURE_DIR_COMPONENTS] = "stage_ensure_dir_components",
	[ACTIONDFS_STAT_STAGE_ENSURE_DIR_EXISTING] = "stage_ensure_dir_existing",
	[ACTIONDFS_STAT_STAGE_ENSURE_DIR_CREATED] = "stage_ensure_dir_created",
	[ACTIONDFS_STAT_STAGE_ENSURE_DIR_ERRORS] = "stage_ensure_dir_errors",
	[ACTIONDFS_STAT_STAGE_ENSURE_DIR_READY_HITS] = "stage_ensure_dir_ready_hits",
	[ACTIONDFS_STAT_STAGE_INODE_LOOKUPS] = "stage_inode_lookups",
	[ACTIONDFS_STAT_STAGE_INODE_LOOKUP_SKIPPED_EMPTY_DIR] = "stage_inode_lookup_skipped_empty_dir",
	[ACTIONDFS_STAT_STAGE_INODE_LOOKUP_HITS] = "stage_inode_lookup_hits",
	[ACTIONDFS_STAT_STAGE_INODE_LOOKUP_NEGATIVE] = "stage_inode_lookup_negative",
	[ACTIONDFS_STAT_STAGE_INODE_LOOKUP_ERRORS] = "stage_inode_lookup_errors",
	[ACTIONDFS_STAT_STAGE_INODE_LOOKUP_INPUT_DIR_MERGES] = "stage_inode_lookup_input_dir_merges",
	[ACTIONDFS_STAT_STAGE_BACKING_OPEN_ATTEMPTS] = "stage_backing_open_attempts",
	[ACTIONDFS_STAT_STAGE_BACKING_OPEN_FAILURES] = "stage_backing_open_failures",
	[ACTIONDFS_STAT_STAGE_BACKING_OPEN_CACHED_HITS] = "stage_backing_open_cached_hits",
	[ACTIONDFS_STAT_STAGE_BACKING_OPEN_CACHED_MISSES] = "stage_backing_open_cached_misses",
	[ACTIONDFS_STAT_STAGE_BACKING_OPEN_READ_CALLS] = "stage_backing_open_read_calls",
	[ACTIONDFS_STAT_STAGE_BACKING_OPEN_WRITE_CALLS] = "stage_backing_open_write_calls",
	[ACTIONDFS_STAT_STAGE_BACKING_OPEN_SPLICE_READ_CALLS] = "stage_backing_open_splice_read_calls",
	[ACTIONDFS_STAT_STAGE_BACKING_OPEN_MMAP_CALLS] = "stage_backing_open_mmap_calls",
	[ACTIONDFS_STAT_STAGE_BACKING_OPEN_TOTAL_NS] = "stage_backing_open_total_ns",
	[ACTIONDFS_STAT_STAGE_BACKING_OPEN_LOOKUP_NS] = "stage_backing_open_lookup_ns",
	[ACTIONDFS_STAT_STAGE_BACKING_OPEN_FILE_NS] = "stage_backing_open_file_ns",
	[ACTIONDFS_STAT_STAGE_REAL_OPEN_ATTEMPTS] = "stage_real_open_attempts",
	[ACTIONDFS_STAT_STAGE_REAL_OPEN_FAILURES] = "stage_real_open_failures",
	[ACTIONDFS_STAT_STAGE_REAL_OPEN_COPY_IN_CALLS] = "stage_real_open_copy_in_calls",
	[ACTIONDFS_STAT_STAGE_REAL_OPEN_COPY_OUT_CALLS] = "stage_real_open_copy_out_calls",
	[ACTIONDFS_STAT_STAGE_REAL_OPEN_NS] = "stage_real_open_ns",
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

static const struct inode_operations actiondfs_dir_iops;
static const struct inode_operations actiondfs_file_iops;
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
	kfree(node->stage_rel);
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
	node->origin = ACTIONDFS_NODE_INPUT;
	node->ino = atomic64_inc_return(&sbi->next_ino);
	node->mode = mode;
	node->loaded = true;
	node->stage_children_known_empty = true;
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
	node->origin = ACTIONDFS_NODE_INPUT;
	node->ino = atomic64_inc_return(&sbi->next_ino);
	node->mode = mode;
	node->loaded = true;
	node->stage_children_known_empty = true;
	mutex_init(&node->blob_lock);
	return node;
}

static struct actiondfs_node *actiondfs_alloc_node(struct actiondfs_sb_info *sbi,
						   const char *name,
						   umode_t mode)
{
	return actiondfs_alloc_node_len(sbi, name, strlen(name), mode);
}

static struct actiondfs_node *
actiondfs_alloc_staged_node(struct actiondfs_sb_info *sbi,
			    struct actiondfs_node *parent,
			    const char *name, size_t name_len,
			    umode_t mode, u64 size, char *stage_rel)
{
	struct actiondfs_node *node;

	node = actiondfs_alloc_node_len(sbi, name, name_len, mode);
	if (!node)
		return NULL;
	node->origin = ACTIONDFS_NODE_STAGED;
	node->parent = parent;
	node->stage_rel = stage_rel;
	node->size = size;
	if (S_ISDIR(mode))
		node->stage_dir_ready = true;
	return node;
}

static bool actiondfs_stage_children_known_empty(const struct actiondfs_node *node)
{
	return READ_ONCE(node->stage_children_known_empty);
}

static void actiondfs_mark_stage_children_maybe_present(struct actiondfs_node *node)
{
	WRITE_ONCE(node->stage_children_known_empty, false);
}

static bool actiondfs_stage_dir_ready(const struct actiondfs_node *node)
{
	return READ_ONCE(node->stage_dir_ready);
}

static void actiondfs_mark_stage_dir_ready(struct actiondfs_node *node)
{
	while (node) {
		if (actiondfs_is_dir(node))
			WRITE_ONCE(node->stage_dir_ready, true);
		node = node->parent;
	}
}

static char *actiondfs_node_rel_path(struct actiondfs_node *node)
{
	struct actiondfs_node *cursor;
	char *path;
	size_t len = 0;
	size_t pos;

	if (node->origin == ACTIONDFS_NODE_STAGED && node->stage_rel)
		return kstrdup(node->stage_rel, GFP_KERNEL);
	if (!node->parent)
		return kstrdup("", GFP_KERNEL);

	for (cursor = node; cursor && cursor->parent; cursor = cursor->parent)
		len += cursor->name_len + (cursor->parent->parent ? 1 : 0);

	path = kmalloc(len + 1, GFP_KERNEL);
	if (!path)
		return NULL;
	path[len] = '\0';
	pos = len;
	for (cursor = node; cursor && cursor->parent; cursor = cursor->parent) {
		pos -= cursor->name_len;
		memcpy(path + pos, cursor->name, cursor->name_len);
		if (cursor->parent->parent)
			path[--pos] = '/';
	}
	return path;
}

static char *actiondfs_child_rel_path(struct actiondfs_node *parent,
				      const char *name, size_t name_len)
{
	char *parent_path;
	char *path;

	parent_path = actiondfs_node_rel_path(parent);
	if (!parent_path)
		return NULL;
	if (!parent_path[0]) {
		path = kmemdup_nul(name, name_len, GFP_KERNEL);
	} else {
		path = kasprintf(GFP_KERNEL, "%s/%.*s", parent_path,
				 (int)name_len, name);
	}
	kfree(parent_path);
	return path;
}

static int actiondfs_stage_parent_path(struct actiondfs_sb_info *sbi,
				       struct actiondfs_node *parent,
				       struct path *path)
{
	char *rel;
	int err;

	if (!sbi->stage_path_valid) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_PARENT_PATH_ERRORS);
		return -EROFS;
	}
	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_PARENT_PATH_LOOKUPS);

	rel = actiondfs_node_rel_path(parent);
	if (!rel) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_PARENT_PATH_ERRORS);
		return -ENOMEM;
	}
	if (!rel[0]) {
		*path = sbi->stage_path;
		path_get(path);
		err = 0;
	} else {
		err = vfs_path_lookup(sbi->stage_path.dentry,
				      sbi->stage_path.mnt, rel,
				      LOOKUP_FOLLOW | LOOKUP_DIRECTORY, path);
	}
	kfree(rel);
	if (err)
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_PARENT_PATH_ERRORS);
	return err;
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
			    mode & 0777);
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

static int actiondfs_stage_ensure_dir(struct actiondfs_sb_info *sbi,
				      const char *rel, umode_t mode)
{
	struct path current_path;
	char *copy;
	char *cursor;
	char *name;
	int err = 0;

	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_ENSURE_DIR_CALLS);
	if (!sbi->stage_path_valid) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_ENSURE_DIR_ERRORS);
		return -EROFS;
	}
	if (!rel[0])
		return 0;

	copy = kstrdup(rel, GFP_KERNEL);
	if (!copy) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_ENSURE_DIR_ERRORS);
		return -ENOMEM;
	}

	current_path = sbi->stage_path;
	path_get(&current_path);
	cursor = copy;
	while ((name = strsep(&cursor, "/")) != NULL) {
		struct path next;
		size_t name_len;

		if (!*name)
			continue;
		name_len = strlen(name);
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_ENSURE_DIR_COMPONENTS);
		if (name_len > NAME_MAX) {
			err = -ENAMETOOLONG;
			break;
		}

		err = vfs_path_lookup(current_path.dentry, current_path.mnt, name,
				      LOOKUP_FOLLOW | LOOKUP_DIRECTORY, &next);
		if (err == -ENOENT) {
			err = actiondfs_stage_mkdir_child(&current_path, name,
							 name_len, mode);
			if (err)
				break;
			actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_ENSURE_DIR_CREATED);
			err = vfs_path_lookup(current_path.dentry,
					      current_path.mnt,
					      name,
					      LOOKUP_FOLLOW | LOOKUP_DIRECTORY,
					      &next);
		} else if (!err) {
			actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_ENSURE_DIR_EXISTING);
		}
		if (err)
			break;

		path_put(&current_path);
		current_path = next;
	}
	path_put(&current_path);
	kfree(copy);
	if (err)
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_ENSURE_DIR_ERRORS);
	return err;
}

static int actiondfs_ensure_stage_dir_for_node(struct actiondfs_sb_info *sbi,
					       struct actiondfs_node *node)
{
	char *rel;
	int err;

	if (actiondfs_stage_dir_ready(node)) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_ENSURE_DIR_READY_HITS);
		return 0;
	}

	rel = actiondfs_node_rel_path(node);
	if (!rel) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_ENSURE_DIR_ERRORS);
		return -ENOMEM;
	}

	err = actiondfs_stage_ensure_dir(sbi, rel, ACTIONDFS_DIR_MODE);
	kfree(rel);
	if (!err)
		actiondfs_mark_stage_dir_ready(node);
	return err;
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
						      u64 size,
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
	dir->size = size;
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
			actiondfs_drop_cached_blob_path(hash);
		if (!actiondfs_retry_open_stale(err, &stale_attempts)) {
			actiondfs_stat_add_elapsed(
				ACTIONDFS_STAT_BLOB_OPEN_BACKING_TOTAL_NS,
				total_start);
			return file;
		}
	}
}

static struct file *actiondfs_open_real_cas_blob(struct actiondfs_sb_info *sbi,
						 const char *hash)
{
	unsigned int stale_attempts = 0;
	struct file *file;
	struct path real_path;
	u64 total_start = actiondfs_stat_time_start();
	int err;

	err = actiondfs_valid_hash(hash);
	if (err)
		return ERR_PTR(err);

	while (true) {
		u64 open_start;
		u64 path_start;

		actiondfs_stat_inc(ACTIONDFS_STAT_BLOB_OPEN_ATTEMPTS);
		path_start = actiondfs_stat_time_start();
		err = actiondfs_get_cached_blob_path(sbi, hash, &real_path);
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_BLOB_OPEN_REAL_PATH_NS,
					   path_start);
		if (err) {
			if (!actiondfs_retry_open_stale(err, &stale_attempts)) {
				actiondfs_stat_add_elapsed(
					ACTIONDFS_STAT_BLOB_OPEN_REAL_TOTAL_NS,
					total_start);
				return ERR_PTR(err);
			}
			continue;
		}

		open_start = actiondfs_stat_time_start();
		file = dentry_open(&real_path, O_RDONLY | O_LARGEFILE,
				   current_cred());
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_BLOB_OPEN_REAL_FILE_NS,
					   open_start);
		path_put(&real_path);
		if (!IS_ERR(file)) {
			actiondfs_stat_add_elapsed(
				ACTIONDFS_STAT_BLOB_OPEN_REAL_TOTAL_NS,
				total_start);
			return file;
		}

		err = PTR_ERR(file);
		if (err == -ESTALE)
			actiondfs_drop_cached_blob_path(hash);
		if (!actiondfs_retry_open_stale(err, &stale_attempts)) {
			actiondfs_stat_add_elapsed(
				ACTIONDFS_STAT_BLOB_OPEN_REAL_TOTAL_NS,
				total_start);
			return file;
		}
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

static struct file *actiondfs_open_staged_backing(struct actiondfs_sb_info *sbi,
						  struct actiondfs_node *node,
						  struct file *actiondfs_file,
						  int flags)
{
	struct path real_path;
	struct file *file;
	u64 total_start = actiondfs_stat_time_start();
	u64 phase_start;
	int err;

	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_BACKING_OPEN_ATTEMPTS);
	if (!sbi->stage_path_valid || !node->stage_rel) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_BACKING_OPEN_FAILURES);
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_BACKING_OPEN_TOTAL_NS,
					   total_start);
		return ERR_PTR(-EROFS);
	}

	phase_start = actiondfs_stat_time_start();
	err = vfs_path_lookup(sbi->stage_path.dentry, sbi->stage_path.mnt,
			      node->stage_rel, LOOKUP_FOLLOW, &real_path);
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

static struct file *actiondfs_open_real_staged(struct actiondfs_sb_info *sbi,
					       struct actiondfs_node *node,
					       int flags)
{
	struct file *file;
	u64 total_start = actiondfs_stat_time_start();

	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_BACKING_OPEN_ATTEMPTS);
	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_REAL_OPEN_ATTEMPTS);
	if (!sbi->stage_path_valid || !node->stage_rel) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_BACKING_OPEN_FAILURES);
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_REAL_OPEN_FAILURES);
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_REAL_OPEN_NS,
					   total_start);
		return ERR_PTR(-EROFS);
	}

	file = file_open_root(&sbi->stage_path, node->stage_rel,
			      flags | O_LARGEFILE, 0);
	if (IS_ERR(file)) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_BACKING_OPEN_FAILURES);
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_REAL_OPEN_FAILURES);
	}
	actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_REAL_OPEN_NS,
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

static bool actiondfs_staged_backing_supports(const struct file *file, int flags)
{
	switch (flags & O_ACCMODE) {
	case O_RDONLY:
		return file->f_mode & FMODE_READ;
	case O_WRONLY:
		return file->f_mode & FMODE_WRITE;
	case O_RDWR:
		return (file->f_mode & FMODE_READ) &&
		       (file->f_mode & FMODE_WRITE);
	default:
		return false;
	}
}

static struct file *
actiondfs_get_staged_backing(struct actiondfs_sb_info *sbi,
			     struct actiondfs_node *node,
			     struct file *actiondfs_file,
			     int flags, bool *need_fput)
{
	struct actiondfs_file_ctx *ctx = actiondfs_file->private_data;

	*need_fput = true;
	if (ctx && ctx->staged_file &&
	    actiondfs_staged_backing_supports(ctx->staged_file, flags)) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_BACKING_OPEN_CACHED_HITS);
		*need_fput = false;
		return ctx->staged_file;
	}

	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_BACKING_OPEN_CACHED_MISSES);
	return actiondfs_open_staged_backing(sbi, node, actiondfs_file, flags);
}

static void actiondfs_put_staged_backing(struct file *file, bool need_fput)
{
	if (need_fput)
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

	if (node->origin == ACTIONDFS_NODE_STAGED) {
		u64 total_start;
		bool need_fput;

		if (!requested)
			return 0;
		total_start = actiondfs_stat_time_start();
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_READ_CALLS);
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_BACKING_OPEN_READ_CALLS);
		file = actiondfs_get_staged_backing(sbi, node, iocb->ki_filp,
						    O_RDONLY, &need_fput);
		if (IS_ERR(file)) {
			actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_READ_TOTAL_NS,
						   total_start);
			return PTR_ERR(file);
		}
		nread = backing_file_read_iter(file, to, iocb, iocb->ki_flags,
					       &ctx);
		actiondfs_put_staged_backing(file, need_fput);
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

static ssize_t actiondfs_write_iter(struct kiocb *iocb, struct iov_iter *from)
{
	struct inode *inode = file_inode(iocb->ki_filp);
	struct actiondfs_node *node = inode->i_private;
	struct actiondfs_sb_info *sbi = actiondfs_sbi(inode->i_sb);
	struct file *file;
	ssize_t nwritten;
	struct backing_file_ctx ctx = {
		.cred = current_cred(),
	};

	if (node->origin != ACTIONDFS_NODE_STAGED)
		return -EROFS;

	{
		u64 total_start = actiondfs_stat_time_start();
		bool need_fput;

		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_WRITE_CALLS);
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_BACKING_OPEN_WRITE_CALLS);
		file = actiondfs_get_staged_backing(sbi, node, iocb->ki_filp,
						    O_WRONLY, &need_fput);
		if (IS_ERR(file)) {
			actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_WRITE_TOTAL_NS,
						   total_start);
			return PTR_ERR(file);
		}
		nwritten = backing_file_write_iter(file, from, iocb,
						   iocb->ki_flags, &ctx);
		if (nwritten > 0) {
			loff_t end = iocb->ki_pos;

			if (end > node->size) {
				node->size = end;
				i_size_write(inode, end);
			}
			actiondfs_stat_add(ACTIONDFS_STAT_STAGE_WRITE_BYTES,
					   (u64)nwritten);
		}
		actiondfs_put_staged_backing(file, need_fput);
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_WRITE_TOTAL_NS,
					   total_start);
	}
	return nwritten;
}

static ssize_t actiondfs_vfs_copy_file_range(struct file *file_in,
					     loff_t *pos_in,
					     struct file *file_out,
					     loff_t *pos_out,
					     size_t len)
{
	loff_t in = *pos_in;
	loff_t out = *pos_out;
	ssize_t copied;

	copied = vfs_copy_file_range(file_in, in, file_out, out, len, 0);
	if (copied > 0) {
		*pos_in = in + copied;
		*pos_out = out + copied;
	}
	return copied;
}

static ssize_t actiondfs_copy_file_range(struct file *file_in, loff_t pos_in,
					 struct file *file_out, loff_t pos_out,
					 size_t len, unsigned int flags)
{
	struct inode *inode_in = file_inode(file_in);
	struct inode *inode_out = file_inode(file_out);
	struct actiondfs_node *node_in = inode_in->i_private;
	struct actiondfs_node *node_out;
	struct actiondfs_sb_info *sbi = actiondfs_sbi(inode_in->i_sb);
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
		real_in = actiondfs_open_real_cas_blob(sbi, node_in->hash);
	} else if (node_in->origin == ACTIONDFS_NODE_STAGED) {
		if (pos_in >= node_in->size) {
			actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_SUCCESS);
			actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_TOTAL_NS,
						   total_start);
			return 0;
		}
		len = min_t(u64, (u64)len, node_in->size - pos_in);
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_REAL_OPEN_COPY_IN_CALLS);
		real_in = actiondfs_open_real_staged(sbi, node_in, O_RDONLY);
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

	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_REAL_OPEN_COPY_OUT_CALLS);
	real_out = actiondfs_open_real_staged(sbi, node_out, O_WRONLY);
	if (IS_ERR(real_out)) {
		fput(real_in);
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_FALLBACKS);
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_TOTAL_NS,
					   total_start);
		return PTR_ERR(real_out);
	}

	copied = actiondfs_vfs_copy_file_range(real_in, &pos_in, real_out,
					       &pos_out, len);
	fput(real_out);
	fput(real_in);
	if (copied > 0) {
		loff_t end = pos_out;

		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_COPY_FILE_RANGE_SUCCESS);
		if (end > node_out->size) {
			node_out->size = end;
			i_size_write(inode_out, end);
		}
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
		bool need_fput;

		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_SPLICE_READ_CALLS);
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_BACKING_OPEN_SPLICE_READ_CALLS);
		file = actiondfs_get_staged_backing(sbi, node, actiondfs_file,
						    O_RDONLY, &need_fput);
		if (IS_ERR(file)) {
			actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_SPLICE_READ_TOTAL_NS,
						   total_start);
			return PTR_ERR(file);
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
		actiondfs_put_staged_backing(file, need_fput);
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

	if (node->origin == ACTIONDFS_NODE_STAGED) {
		u64 total_start = actiondfs_stat_time_start();
		bool need_fput;

		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_MMAP_CALLS);
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_BACKING_OPEN_MMAP_CALLS);
		file = actiondfs_get_staged_backing(
			sbi, node, actiondfs_file,
			actiondfs_staged_backing_flags(actiondfs_file), &need_fput);
		if (IS_ERR(file)) {
			actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_MMAP_FAILURES);
			actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_MMAP_TOTAL_NS,
						   total_start);
			return PTR_ERR(file);
		}
		err = backing_file_mmap(file, vma, &ctx);
		actiondfs_put_staged_backing(file, need_fput);
		if (err)
			actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_MMAP_FAILURES);
		else
			actiondfs_stat_add(ACTIONDFS_STAT_STAGE_MMAP_BYTES,
					   (u64)(vma->vm_end - vma->vm_start));
		actiondfs_stat_add_elapsed(ACTIONDFS_STAT_STAGE_MMAP_TOTAL_NS,
					   total_start);
		return err;
	}

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
						      dir.digest.size,
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
						 dir.digest.size,
						 dir.digest.hash);
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
		actiondfs_stat_inc(ACTIONDFS_STAT_DIRECTORY_BLOB_READS);
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
	memcpy(entry->hash, hash, 64);
	entry->hash[64] = '\0';

	err = actiondfs_read_cas_blob(sbi, hash, expected_size, &buffer, &len);
	if (err)
		goto fail;
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
	entry = actiondfs_find_cached_dir_locked(hash);
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
	existing = actiondfs_find_cached_dir_locked(hash);
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

		err = actiondfs_get_cached_dir(sbi, dir->hash, dir->size,
					       &cached);
		if (err)
			return err;
		return actiondfs_attach_cached_dir(dir, cached);
	}

	if (!dir->parent)
		actiondfs_stat_inc(ACTIONDFS_STAT_ROOT_DIR_PARSES);
	err = actiondfs_read_cas_blob(sbi, dir->hash, dir->size, &buffer, &len);
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
		} else if (str_has_prefix(token, "root_size=")) {
			if (kstrtoull(token + 10, 10, &sbi->root_size)) {
				kfree(options);
				return -EINVAL;
			}
		} else if (str_has_prefix(token, "cas=")) {
			kfree(sbi->cas_root);
			sbi->cas_root = kstrdup(token + 4, GFP_KERNEL);
			if (!sbi->cas_root) {
				kfree(options);
				return -ENOMEM;
			}
		} else if (str_has_prefix(token, "stage=")) {
			kfree(sbi->stage_root);
			sbi->stage_root = kstrdup(token + 6, GFP_KERNEL);
			if (!sbi->stage_root) {
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
	if (sbi->root_size != ACTIONDFS_UNKNOWN_SIZE &&
	    sbi->root_size > ACTIONDFS_MAX_DIRECTORY_PROTO_SIZE)
		return -EINVAL;
	if (strchr(sbi->cas_root, ','))
		return -EINVAL;
	if (sbi->stage_root && strchr(sbi->stage_root, ','))
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

static struct inode *actiondfs_iget_staged(struct super_block *sb,
					   struct actiondfs_node *parent,
					   const char *name, size_t name_len,
					   umode_t mode, u64 size,
					   char *stage_rel)
{
	struct actiondfs_sb_info *sbi = actiondfs_sbi(sb);
	struct actiondfs_node *node;
	struct inode *inode;

	node = actiondfs_alloc_staged_node(sbi, parent, name, name_len, mode,
					   size, stage_rel);
	if (!node)
		return ERR_PTR(-ENOMEM);

	inode = actiondfs_iget(sb, node);
	if (IS_ERR(inode)) {
		actiondfs_free_tree(node);
		return inode;
	}
	return inode;
}

static struct inode *actiondfs_lookup_staged_inode(struct inode *dir,
						   struct dentry *dentry,
						   struct actiondfs_node *parent)
{
	struct actiondfs_sb_info *sbi = actiondfs_sbi(dir->i_sb);
	struct actiondfs_node *input_child = NULL;
	struct actiondfs_cached_dir *input_cached = NULL;
	struct path real_path;
	struct inode *real_inode;
	struct inode *inode;
	struct actiondfs_node *node;
	struct kstat stat;
	char *rel;
	umode_t mode;
	u64 size = 0;
	int err;

	if (!sbi->staged_writes)
		return NULL;
	if (actiondfs_stage_children_known_empty(parent)) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUP_SKIPPED_EMPTY_DIR);
		return NULL;
	}

	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUPS);
	rel = actiondfs_child_rel_path(parent, dentry->d_name.name,
				       dentry->d_name.len);
	if (!rel) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUP_ERRORS);
		return ERR_PTR(-ENOMEM);
	}

	err = vfs_path_lookup(sbi->stage_path.dentry, sbi->stage_path.mnt,
			      rel, LOOKUP_FOLLOW, &real_path);
	if (err) {
		kfree(rel);
		if (err == -ENOENT) {
			actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUP_NEGATIVE);
			return NULL;
		}
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUP_ERRORS);
		return ERR_PTR(err);
	}

	real_inode = d_inode(real_path.dentry);
	mode = real_inode->i_mode;
	if (S_ISDIR(mode)) {
		mode = S_IFDIR | ACTIONDFS_DIR_MODE;
		input_child = actiondfs_lookup_child(sbi, parent,
						     dentry->d_name.name,
						     dentry->d_name.len);
		if (IS_ERR(input_child)) {
			path_put(&real_path);
			kfree(rel);
			actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUP_ERRORS);
			return ERR_CAST(input_child);
		}
		if (input_child && actiondfs_is_dir(input_child)) {
			err = actiondfs_get_cached_dir(sbi, input_child->hash,
						       input_child->size,
						       &input_cached);
			if (err && err != -ENOENT) {
				path_put(&real_path);
				kfree(rel);
				actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUP_ERRORS);
				return ERR_PTR(err);
			}
		}
	} else if (S_ISREG(mode)) {
		mode = S_IFREG | (mode & 0777);
		err = vfs_getattr(&real_path, &stat, STATX_SIZE,
				  AT_STATX_SYNC_AS_STAT);
		if (!err)
			size = stat.size;
	} else {
		path_put(&real_path);
		kfree(rel);
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUP_NEGATIVE);
		return NULL;
	}
	path_put(&real_path);

	inode = actiondfs_iget_staged(dir->i_sb, parent, dentry->d_name.name,
				      dentry->d_name.len, mode, size, rel);
	if (IS_ERR(inode)) {
		kfree(rel);
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUP_ERRORS);
	} else {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUP_HITS);
	}
	if (!IS_ERR(inode) && S_ISDIR(mode) && input_cached) {
		node = inode->i_private;
		actiondfs_mark_stage_children_maybe_present(node);
		memcpy(node->hash, input_child->hash, 64);
		node->hash[64] = '\0';
		node->cached_dir = input_cached;
		node->loaded = true;
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_INODE_LOOKUP_INPUT_DIR_MERGES);
	} else if (!IS_ERR(inode) && S_ISDIR(mode)) {
		node = inode->i_private;
		actiondfs_mark_stage_children_maybe_present(node);
	}
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
	inode = actiondfs_lookup_staged_inode(dir, dentry, parent);
	if (IS_ERR(inode))
		return ERR_CAST(inode);
	if (inode) {
		actiondfs_stat_inc(ACTIONDFS_STAT_LOOKUP_HITS);
		child = NULL;
	} else {
		child = actiondfs_lookup_child(actiondfs_sbi(dir->i_sb), parent,
					       dentry->d_name.name,
					       dentry->d_name.len);
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
	}

	d_add(dentry, inode);
	return NULL;
}

static int actiondfs_create(struct mnt_idmap *idmap, struct inode *dir,
			    struct dentry *dentry, umode_t mode, bool excl)
{
	struct actiondfs_node *parent = dir->i_private;
	struct actiondfs_sb_info *sbi = actiondfs_sbi(dir->i_sb);
	struct actiondfs_node *input_child;
	struct inode *inode;
	struct path parent_path;
	struct dentry *real_dentry;
	char *rel;
	int err;

	if (!sbi->staged_writes)
		return -EROFS;
	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_CREATE_CALLS);
	err = actiondfs_ensure_loaded(dir->i_sb, parent);
	if (err) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_CREATE_FAILURES);
		return err;
	}
	input_child = actiondfs_lookup_child(sbi, parent, dentry->d_name.name,
					     dentry->d_name.len);
	if (IS_ERR(input_child)) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_CREATE_FAILURES);
		return PTR_ERR(input_child);
	}
	if (input_child) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_CREATE_FAILURES);
		return -EROFS;
	}

	rel = actiondfs_child_rel_path(parent, dentry->d_name.name,
				       dentry->d_name.len);
	if (!rel) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_CREATE_FAILURES);
		return -ENOMEM;
	}

	err = actiondfs_ensure_stage_dir_for_node(sbi, parent);
	if (err)
		goto out_free_rel;

	err = actiondfs_stage_parent_path(sbi, parent, &parent_path);
	if (err)
		goto out_free_rel;
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
	dput(real_dentry);
	if (err)
		goto out_drop_write;

	inode = actiondfs_iget_staged(dir->i_sb, parent, dentry->d_name.name,
				      dentry->d_name.len,
				      S_IFREG | (mode & 0777), 0, rel);
	if (IS_ERR(inode)) {
		err = PTR_ERR(inode);
		goto out_drop_write;
	}
	d_instantiate(dentry, inode);
	actiondfs_mark_stage_children_maybe_present(parent);
	rel = NULL;
	err = 0;

out_drop_write:
	mnt_drop_write(parent_path.mnt);
out_put_path:
	path_put(&parent_path);
out_free_rel:
	kfree(rel);
	if (err)
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_CREATE_FAILURES);
	else
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_CREATE_SUCCESS);
	return err;
}

static struct dentry *actiondfs_mkdir(struct mnt_idmap *idmap,
				      struct inode *dir,
				      struct dentry *dentry, umode_t mode)
{
	struct actiondfs_node *parent = dir->i_private;
	struct actiondfs_sb_info *sbi = actiondfs_sbi(dir->i_sb);
	struct actiondfs_node *input_child;
	struct inode *inode;
	struct path parent_path;
	struct dentry *real_dentry;
	struct dentry *created;
	char *rel;
	int err;

	if (!sbi->staged_writes)
		return ERR_PTR(-EROFS);
	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_MKDIR_CALLS);
	err = actiondfs_ensure_loaded(dir->i_sb, parent);
	if (err) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_MKDIR_FAILURES);
		return ERR_PTR(err);
	}
	input_child = actiondfs_lookup_child(sbi, parent, dentry->d_name.name,
					     dentry->d_name.len);
	if (IS_ERR(input_child)) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_MKDIR_FAILURES);
		return ERR_CAST(input_child);
	}
	if (input_child) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_MKDIR_FAILURES);
		return ERR_PTR(-EROFS);
	}

	rel = actiondfs_child_rel_path(parent, dentry->d_name.name,
				       dentry->d_name.len);
	if (!rel) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_MKDIR_FAILURES);
		return ERR_PTR(-ENOMEM);
	}

	err = actiondfs_ensure_stage_dir_for_node(sbi, parent);
	if (err) {
		kfree(rel);
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_MKDIR_FAILURES);
		return ERR_PTR(err);
	}

	err = actiondfs_stage_parent_path(sbi, parent, &parent_path);
	if (err) {
		kfree(rel);
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_MKDIR_FAILURES);
		return ERR_PTR(err);
	}
	err = mnt_want_write(parent_path.mnt);
	if (err)
		goto out_put_path;
	err = actiondfs_stage_lookup_child(&parent_path, dentry->d_name.name,
					   dentry->d_name.len, &real_dentry);
	if (err)
		goto out_drop_write;
	created = vfs_mkdir(mnt_idmap(parent_path.mnt),
			    d_inode(parent_path.dentry), real_dentry,
			    mode & 0777);
	if (IS_ERR(created)) {
		err = PTR_ERR(created);
		inode_unlock(d_inode(parent_path.dentry));
	} else {
		err = 0;
		dput(created);
		inode_unlock(d_inode(parent_path.dentry));
	}
	if (err)
		goto out_drop_write;

	inode = actiondfs_iget_staged(dir->i_sb, parent, dentry->d_name.name,
				      dentry->d_name.len,
				      S_IFDIR | ACTIONDFS_DIR_MODE, 0, rel);
	if (IS_ERR(inode)) {
		err = PTR_ERR(inode);
		goto out_drop_write;
	}
	inc_nlink(dir);
	d_instantiate(dentry, inode);
	actiondfs_mark_stage_children_maybe_present(parent);
	rel = NULL;

out_drop_write:
	mnt_drop_write(parent_path.mnt);
out_put_path:
	path_put(&parent_path);
	kfree(rel);
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
	err = actiondfs_stage_parent_path(sbi, parent, &parent_path);
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

	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_RMDIR_CALLS);
	err = actiondfs_stage_parent_path(sbi, parent, &parent_path);
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
	if (!err)
		drop_nlink(dir);
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
	char *new_rel = NULL;
	int err;

	if (flags & ~RENAME_NOREPLACE)
		return -EINVAL;
	if (old_node->origin != ACTIONDFS_NODE_STAGED)
		return -EROFS;
	if (new_node && new_node->origin != ACTIONDFS_NODE_STAGED)
		return -EROFS;

	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_RENAME_CALLS);
	new_rel = actiondfs_child_rel_path(new_parent, new_dentry->d_name.name,
					   new_dentry->d_name.len);
	if (!new_rel) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_RENAME_FAILURES);
		return -ENOMEM;
	}
	err = actiondfs_stage_parent_path(sbi, old_parent, &old_parent_path);
	if (err)
		goto out_free_rel;
	err = actiondfs_stage_parent_path(sbi, new_parent, &new_parent_path);
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
		kfree(old_node->stage_rel);
		old_node->stage_rel = new_rel;
		old_node->parent = new_parent;
		actiondfs_mark_stage_children_maybe_present(new_parent);
		new_rel = NULL;
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
out_free_rel:
	kfree(new_rel);
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
	struct actiondfs_file_ctx *ctx;
	struct file *staged_file;

	if (node->origin != ACTIONDFS_NODE_STAGED &&
	    (file->f_mode & FMODE_WRITE))
		return -EROFS;
	if (node->origin != ACTIONDFS_NODE_STAGED)
		return 0;

	ctx = kzalloc(sizeof(*ctx), GFP_KERNEL);
	if (!ctx)
		return -ENOMEM;

	staged_file = actiondfs_open_staged_backing(
		sbi, node, file, actiondfs_staged_backing_flags(file));
	if (IS_ERR(staged_file)) {
		kfree(ctx);
		return PTR_ERR(staged_file);
	}
	ctx->staged_file = staged_file;
	file->private_data = ctx;
	return 0;
}

static int actiondfs_release(struct inode *inode, struct file *file)
{
	struct actiondfs_file_ctx *ctx = file->private_data;

	if (!ctx)
		return 0;
	if (ctx->staged_file)
		fput(ctx->staged_file);
	kfree(ctx);
	file->private_data = NULL;
	return 0;
}

static int actiondfs_setattr(struct mnt_idmap *idmap, struct dentry *dentry,
			     struct iattr *attr)
{
	struct inode *inode = d_inode(dentry);
	struct actiondfs_node *node = inode->i_private;
	struct actiondfs_sb_info *sbi = actiondfs_sbi(inode->i_sb);
	struct path real_path;
	int err;

	if (node->origin != ACTIONDFS_NODE_STAGED)
		return -EROFS;
	if (attr->ia_valid & ATTR_SIZE) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_SETATTR_SIZE_CALLS);
		err = vfs_path_lookup(sbi->stage_path.dentry,
				      sbi->stage_path.mnt, node->stage_rel,
				      LOOKUP_FOLLOW, &real_path);
		if (err) {
			actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_SETATTR_SIZE_FAILURES);
			return err;
		}
		err = vfs_truncate(&real_path, attr->ia_size);
		path_put(&real_path);
		if (err) {
			actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_SETATTR_SIZE_FAILURES);
			return err;
		}
		node->size = attr->ia_size;
		i_size_write(inode, attr->ia_size);
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_SETATTR_SIZE_SUCCESS);
	}
	setattr_copy(&nop_mnt_idmap, inode, attr);
	mark_inode_dirty(inode);
	return 0;
}

struct actiondfs_stage_readdir_ctx {
	struct dir_context ctx;
	struct dir_context *orig;
	struct actiondfs_sb_info *sbi;
	struct actiondfs_node *dir;
	loff_t base;
};

static bool actiondfs_stage_filldir(struct dir_context *ctx, const char *name,
				    int namelen, loff_t offset, u64 ino,
				    unsigned int d_type)
{
	struct actiondfs_stage_readdir_ctx *stage_ctx =
		container_of(ctx, struct actiondfs_stage_readdir_ctx, ctx);
	struct actiondfs_node *input_child;

	if ((namelen == 1 && name[0] == '.') ||
	    (namelen == 2 && name[0] == '.' && name[1] == '.')) {
		stage_ctx->orig->pos = stage_ctx->base + offset + 1;
		return true;
	}

	input_child = actiondfs_lookup_child(stage_ctx->sbi, stage_ctx->dir,
					     name, namelen);
	if (IS_ERR(input_child))
		return false;
	if (input_child) {
		stage_ctx->orig->pos = stage_ctx->base + offset + 1;
		return true;
	}

	if (!dir_emit(stage_ctx->orig, name, namelen, ino, d_type))
		return false;
	actiondfs_stat_inc(ACTIONDFS_STAT_READDIR_ENTRIES);
	stage_ctx->orig->pos = stage_ctx->base + offset + 1;
	return true;
}

static int actiondfs_iterate_stage_dir(struct inode *inode,
				       struct actiondfs_node *dir,
				       struct dir_context *ctx,
				       loff_t base)
{
	struct actiondfs_sb_info *sbi = actiondfs_sbi(inode->i_sb);
	struct actiondfs_stage_readdir_ctx stage_ctx;
	struct file *file;
	char *rel;
	int err;

	if (!sbi->staged_writes)
		return 0;

	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_READDIR_CALLS);
	rel = actiondfs_node_rel_path(dir);
	if (!rel) {
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_READDIR_ERRORS);
		return -ENOMEM;
	}
	file = file_open_root(&sbi->stage_path, rel, O_RDONLY | O_DIRECTORY, 0);
	kfree(rel);
	if (IS_ERR(file)) {
		err = PTR_ERR(file);
		if (err == -ENOENT) {
			actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_READDIR_MISSES);
			return 0;
		}
		actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_READDIR_ERRORS);
		return err;
	}
	actiondfs_stat_inc(ACTIONDFS_STAT_STAGE_READDIR_HITS);

	file->f_pos = ctx->pos > base ? ctx->pos - base : 0;
	stage_ctx = (struct actiondfs_stage_readdir_ctx){
		.ctx = {
			.actor = actiondfs_stage_filldir,
			.pos = file->f_pos,
			.count = ctx->count,
		},
		.orig = ctx,
		.sbi = sbi,
		.dir = dir,
		.base = base,
	};
	err = iterate_dir(file, &stage_ctx.ctx);
	fput(file);
	return err;
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
		base += cached->dir_count;
	} else {
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
		base += dir->dir_count;
	}
	return actiondfs_iterate_stage_dir(inode, dir, ctx, base);
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
	.setattr = actiondfs_setattr,
};

static const struct file_operations actiondfs_file_fops = {
	.open = actiondfs_open,
	.release = actiondfs_release,
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
	.mkdir = actiondfs_mkdir,
	.unlink = actiondfs_unlink,
	.rmdir = actiondfs_rmdir,
	.rename = actiondfs_rename,
	.getattr = simple_getattr,
	.setattr = actiondfs_setattr,
};

static const struct file_operations actiondfs_dir_fops = {
	.llseek = generic_file_llseek,
	.read = generic_read_dir,
	.iterate_shared = actiondfs_iterate_shared,
};

static void actiondfs_evict_inode(struct inode *inode)
{
	struct actiondfs_node *node = inode->i_private;

	truncate_inode_pages_final(&inode->i_data);
	clear_inode(inode);
	if (node && node->origin == ACTIONDFS_NODE_STAGED)
		actiondfs_free_tree(node);
}

static void actiondfs_put_super(struct super_block *sb)
{
	struct actiondfs_sb_info *sbi = actiondfs_sbi(sb);

	if (!sbi)
		return;
	actiondfs_free_tree(sbi->root);
	if (sbi->cas_path_valid)
		path_put(&sbi->cas_path);
	if (sbi->stage_path_valid)
		path_put(&sbi->stage_path);
	kfree(sbi->cas_root);
	kfree(sbi->root_hash);
	kfree(sbi->stage_root);
	kfree(sbi);
	sb->s_fs_info = NULL;
}

static const struct super_operations actiondfs_super_ops = {
	.statfs = simple_statfs,
	.put_super = actiondfs_put_super,
	.evict_inode = actiondfs_evict_inode,
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
	sbi->root_size = ACTIONDFS_UNKNOWN_SIZE;
	mutex_init(&sbi->load_lock);
	atomic64_set(&sbi->next_ino, 0);
	sb->s_magic = ACTIONDFS_MAGIC;
	sb->s_maxbytes = MAX_LFS_FILESIZE;
	sb->s_blocksize = PAGE_SIZE;
	sb->s_blocksize_bits = PAGE_SHIFT;
	sb->s_flags |= SB_NOATIME;
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
	if (sbi->stage_root) {
		err = kern_path(sbi->stage_root, LOOKUP_FOLLOW | LOOKUP_DIRECTORY,
				&sbi->stage_path);
		if (err)
			goto fail;
		sbi->stage_path_valid = true;
		sbi->staged_writes = true;
		actiondfs_mark_stage_children_maybe_present(sbi->root);
		actiondfs_mark_stage_dir_ready(sbi->root);
	} else {
		sb->s_flags |= SB_RDONLY;
	}
	memcpy(sbi->root->hash, sbi->root_hash, 64);
	sbi->root->hash[64] = '\0';
	sbi->root->size = sbi->root_size;
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

static struct file_system_type *actiondfs_fs_types[] = {
	&actiondfs_fs_type,
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
	size_t i;
	int err;

	for (i = 0; i < ARRAY_SIZE(actiondfs_fs_types); i++) {
		err = register_filesystem(actiondfs_fs_types[i]);
		if (err)
			goto fail;
	}
#if ACTIONDFS_ENABLE_STATS
	if (!proc_create_single(ACTIONDFS_PROC_STATS, 0444, NULL,
				actiondfs_stats_show)) {
		err = -ENOMEM;
		goto fail;
	}
#endif
	return 0;

fail:
	while (i > 0)
		unregister_filesystem(actiondfs_fs_types[--i]);
	return err;
}

static void __exit actiondfs_exit(void)
{
	size_t i;

#if ACTIONDFS_ENABLE_STATS
	remove_proc_entry(ACTIONDFS_PROC_STATS, NULL);
#endif
	for (i = ARRAY_SIZE(actiondfs_fs_types); i > 0; i--)
		unregister_filesystem(actiondfs_fs_types[i - 1]);
	actiondfs_destroy_blob_path_cache();
	actiondfs_destroy_dir_cache();
}

module_init(actiondfs_init);
module_exit(actiondfs_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("actiond manifest filesystem");
