/*
 * Writes PIRInclude.Linux.API.Layout.inc: the size of every record,
 * the offset of every field and the value of every constant of
 * linux/io_uring.h, as checks of the Pascal translation
 * (PIRUnit.Linux.API).
 *
 * Do not run this by hand: Generate-LinuxApiLayout.sh builds and runs it, and
 * also checks that this list names everything in the header.
 *
 * The output is Pascal: three procedures, each taking the check method of the
 * test (ACheck(Name, C value, Pascal value)). A name that the Pascal unit
 * does not have is a compile error of the test program.
 */
#include <stddef.h>
#include <stdio.h>
#include <asm/unistd.h>
#include <linux/io_uring.h>
#include <linux/version.h>

/* sizeof(struct s) */
#define SIZE(s) \
	printf("  ACheck('SizeOf(%s)', %zu, SizeOf(%s));\n", #s, sizeof(struct s), #s)

/* offsetof(struct s, f); p is the Pascal name of the field */
#define FIELD_AS(s, f, p) \
	printf("  ACheck('%s.%s', %zu, OffsetOf(@P%s(nil)^.%s));\n", #s, #f, offsetof(struct s, f), #s, p)
#define FIELD(s, f) FIELD_AS(s, f, #f)

/* A C flexible array (f[]) that is not a field in Pascal: it starts right
 * after the record */
#define FLEX(s, f) \
	printf("  ACheck('%s.%s (right after the record)', %zu, SizeOf(%s));\n", #s, #f, offsetof(struct s, f), #s)

#define CONST(c) \
	printf("  ACheck('%s', %lld, %s);\n", #c, (long long)(c), #c)

static void sizes(void)
{
	printf("procedure CheckSizes(const ACheck: TLayoutCheck);\nbegin\n");
	SIZE(io_uring_sqe);
	SIZE(io_uring_cqe);
	SIZE(io_sqring_offsets);
	SIZE(io_cqring_offsets);
	SIZE(io_uring_params);
	SIZE(io_uring_files_update);
	SIZE(io_uring_rsrc_register);
	SIZE(io_uring_rsrc_update);
	SIZE(io_uring_rsrc_update2);
	SIZE(io_uring_probe_op);
	SIZE(io_uring_probe);
	SIZE(io_uring_restriction);
	SIZE(io_uring_buf);
	SIZE(io_uring_buf_ring);
	SIZE(io_uring_buf_reg);
	SIZE(io_uring_buf_status);
	SIZE(__kernel_timespec);
	SIZE(io_uring_getevents_arg);
	SIZE(io_uring_sync_cancel_reg);
	SIZE(io_uring_file_index_range);
	SIZE(io_uring_recvmsg_out);
	printf("end;\n\n");
}

static void offsets(void)
{
	printf("procedure CheckOffsets(const ACheck: TLayoutCheck);\nbegin\n");

	FIELD(io_uring_sqe, opcode);
	FIELD(io_uring_sqe, flags);
	FIELD(io_uring_sqe, ioprio);
	FIELD(io_uring_sqe, fd);
	FIELD(io_uring_sqe, off);
	FIELD(io_uring_sqe, addr2);
	FIELD(io_uring_sqe, cmd_op);
	FIELD(io_uring_sqe, __pad1);
	FIELD(io_uring_sqe, addr);
	FIELD(io_uring_sqe, splice_off_in);
	FIELD(io_uring_sqe, level);
	FIELD(io_uring_sqe, optname);
	FIELD(io_uring_sqe, len);
	FIELD(io_uring_sqe, rw_flags);
	FIELD(io_uring_sqe, fsync_flags);
	FIELD(io_uring_sqe, poll_events);
	FIELD(io_uring_sqe, poll32_events);
	FIELD(io_uring_sqe, sync_range_flags);
	FIELD(io_uring_sqe, msg_flags);
	FIELD(io_uring_sqe, timeout_flags);
	FIELD(io_uring_sqe, accept_flags);
	FIELD(io_uring_sqe, cancel_flags);
	FIELD(io_uring_sqe, open_flags);
	FIELD(io_uring_sqe, statx_flags);
	FIELD(io_uring_sqe, fadvise_advice);
	FIELD(io_uring_sqe, splice_flags);
	FIELD(io_uring_sqe, rename_flags);
	FIELD(io_uring_sqe, unlink_flags);
	FIELD(io_uring_sqe, hardlink_flags);
	FIELD(io_uring_sqe, xattr_flags);
	FIELD(io_uring_sqe, msg_ring_flags);
	FIELD(io_uring_sqe, uring_cmd_flags);
	FIELD(io_uring_sqe, waitid_flags);
	FIELD(io_uring_sqe, futex_flags);
	FIELD(io_uring_sqe, install_fd_flags);
	FIELD(io_uring_sqe, user_data);
	FIELD(io_uring_sqe, buf_index);
	FIELD(io_uring_sqe, buf_group);
	FIELD(io_uring_sqe, personality);
	FIELD(io_uring_sqe, splice_fd_in);
	FIELD(io_uring_sqe, file_index);
	FIELD(io_uring_sqe, optlen);
	FIELD(io_uring_sqe, addr_len);
	FIELD(io_uring_sqe, __pad3);
	FIELD(io_uring_sqe, addr3);
	FIELD(io_uring_sqe, __pad2);
	FIELD(io_uring_sqe, optval);
	FIELD(io_uring_sqe, cmd);

	FIELD(io_uring_cqe, user_data);
	FIELD(io_uring_cqe, res);
	FIELD(io_uring_cqe, flags);
	FLEX(io_uring_cqe, big_cqe);

	FIELD(io_sqring_offsets, head);
	FIELD(io_sqring_offsets, tail);
	FIELD(io_sqring_offsets, ring_mask);
	FIELD(io_sqring_offsets, ring_entries);
	FIELD(io_sqring_offsets, flags);
	FIELD(io_sqring_offsets, dropped);
	FIELD_AS(io_sqring_offsets, array, "&array");
	FIELD(io_sqring_offsets, resv1);
	FIELD(io_sqring_offsets, user_addr);

	FIELD(io_cqring_offsets, head);
	FIELD(io_cqring_offsets, tail);
	FIELD(io_cqring_offsets, ring_mask);
	FIELD(io_cqring_offsets, ring_entries);
	FIELD(io_cqring_offsets, overflow);
	FIELD(io_cqring_offsets, cqes);
	FIELD(io_cqring_offsets, flags);
	FIELD(io_cqring_offsets, resv1);
	FIELD(io_cqring_offsets, user_addr);

	FIELD(io_uring_params, sq_entries);
	FIELD(io_uring_params, cq_entries);
	FIELD(io_uring_params, flags);
	FIELD(io_uring_params, sq_thread_cpu);
	FIELD(io_uring_params, sq_thread_idle);
	FIELD(io_uring_params, features);
	FIELD(io_uring_params, wq_fd);
	FIELD(io_uring_params, resv);
	FIELD(io_uring_params, sq_off);
	FIELD(io_uring_params, cq_off);

	FIELD(io_uring_files_update, offset);
	FIELD(io_uring_files_update, resv);
	FIELD(io_uring_files_update, fds);

	FIELD(io_uring_rsrc_register, nr);
	FIELD(io_uring_rsrc_register, flags);
	FIELD(io_uring_rsrc_register, resv2);
	FIELD(io_uring_rsrc_register, data);
	FIELD(io_uring_rsrc_register, tags);

	FIELD(io_uring_rsrc_update, offset);
	FIELD(io_uring_rsrc_update, resv);
	FIELD(io_uring_rsrc_update, data);

	FIELD(io_uring_rsrc_update2, offset);
	FIELD(io_uring_rsrc_update2, resv);
	FIELD(io_uring_rsrc_update2, data);
	FIELD(io_uring_rsrc_update2, tags);
	FIELD(io_uring_rsrc_update2, nr);
	FIELD(io_uring_rsrc_update2, resv2);

	FIELD(io_uring_probe_op, op);
	FIELD(io_uring_probe_op, resv);
	FIELD(io_uring_probe_op, flags);
	FIELD(io_uring_probe_op, resv2);

	FIELD(io_uring_probe, last_op);
	FIELD(io_uring_probe, ops_len);
	FIELD(io_uring_probe, resv);
	FIELD(io_uring_probe, resv2);
	FLEX(io_uring_probe, ops);

	FIELD(io_uring_restriction, opcode);
	FIELD(io_uring_restriction, register_op);
	FIELD(io_uring_restriction, sqe_op);
	FIELD(io_uring_restriction, sqe_flags);
	FIELD(io_uring_restriction, resv);
	FIELD(io_uring_restriction, resv2);

	FIELD(io_uring_buf, addr);
	FIELD(io_uring_buf, len);
	FIELD(io_uring_buf, bid);
	FIELD(io_uring_buf, resv);

	FIELD(io_uring_buf_ring, resv1);
	FIELD(io_uring_buf_ring, resv2);
	FIELD(io_uring_buf_ring, resv3);
	FIELD(io_uring_buf_ring, tail);
	FIELD(io_uring_buf_ring, bufs);

	FIELD(io_uring_buf_reg, ring_addr);
	FIELD(io_uring_buf_reg, ring_entries);
	FIELD(io_uring_buf_reg, bgid);
	FIELD(io_uring_buf_reg, flags);
	FIELD(io_uring_buf_reg, resv);

	FIELD(io_uring_buf_status, buf_group);
	FIELD(io_uring_buf_status, head);
	FIELD(io_uring_buf_status, resv);

	FIELD(__kernel_timespec, tv_sec);
	FIELD(__kernel_timespec, tv_nsec);

	FIELD(io_uring_getevents_arg, sigmask);
	FIELD(io_uring_getevents_arg, sigmask_sz);
	FIELD(io_uring_getevents_arg, pad);
	FIELD(io_uring_getevents_arg, ts);

	FIELD(io_uring_sync_cancel_reg, addr);
	FIELD(io_uring_sync_cancel_reg, fd);
	FIELD(io_uring_sync_cancel_reg, flags);
	FIELD(io_uring_sync_cancel_reg, timeout);
	FIELD(io_uring_sync_cancel_reg, opcode);
	FIELD(io_uring_sync_cancel_reg, pad);
	FIELD(io_uring_sync_cancel_reg, pad2);

	FIELD(io_uring_file_index_range, off);
	FIELD(io_uring_file_index_range, len);
	FIELD(io_uring_file_index_range, resv);

	FIELD(io_uring_recvmsg_out, namelen);
	FIELD(io_uring_recvmsg_out, controllen);
	FIELD(io_uring_recvmsg_out, payloadlen);
	FIELD(io_uring_recvmsg_out, flags);

	printf("end;\n\n");
}

static void constants(void)
{
	printf("procedure CheckConstants(const ACheck: TLayoutCheck);\nbegin\n");

	CONST(IORING_FILE_INDEX_ALLOC);

	CONST(IOSQE_FIXED_FILE_BIT);
	CONST(IOSQE_IO_DRAIN_BIT);
	CONST(IOSQE_IO_LINK_BIT);
	CONST(IOSQE_IO_HARDLINK_BIT);
	CONST(IOSQE_ASYNC_BIT);
	CONST(IOSQE_BUFFER_SELECT_BIT);
	CONST(IOSQE_CQE_SKIP_SUCCESS_BIT);
	CONST(IOSQE_FIXED_FILE);
	CONST(IOSQE_IO_DRAIN);
	CONST(IOSQE_IO_LINK);
	CONST(IOSQE_IO_HARDLINK);
	CONST(IOSQE_ASYNC);
	CONST(IOSQE_BUFFER_SELECT);
	CONST(IOSQE_CQE_SKIP_SUCCESS);

	CONST(IORING_SETUP_IOPOLL);
	CONST(IORING_SETUP_SQPOLL);
	CONST(IORING_SETUP_SQ_AFF);
	CONST(IORING_SETUP_CQSIZE);
	CONST(IORING_SETUP_CLAMP);
	CONST(IORING_SETUP_ATTACH_WQ);
	CONST(IORING_SETUP_R_DISABLED);
	CONST(IORING_SETUP_SUBMIT_ALL);
	CONST(IORING_SETUP_COOP_TASKRUN);
	CONST(IORING_SETUP_TASKRUN_FLAG);
	CONST(IORING_SETUP_SQE128);
	CONST(IORING_SETUP_CQE32);
	CONST(IORING_SETUP_SINGLE_ISSUER);
	CONST(IORING_SETUP_DEFER_TASKRUN);
	CONST(IORING_SETUP_NO_MMAP);
	CONST(IORING_SETUP_REGISTERED_FD_ONLY);
	CONST(IORING_SETUP_NO_SQARRAY);

	CONST(IORING_OP_NOP);
	CONST(IORING_OP_READV);
	CONST(IORING_OP_WRITEV);
	CONST(IORING_OP_FSYNC);
	CONST(IORING_OP_READ_FIXED);
	CONST(IORING_OP_WRITE_FIXED);
	CONST(IORING_OP_POLL_ADD);
	CONST(IORING_OP_POLL_REMOVE);
	CONST(IORING_OP_SYNC_FILE_RANGE);
	CONST(IORING_OP_SENDMSG);
	CONST(IORING_OP_RECVMSG);
	CONST(IORING_OP_TIMEOUT);
	CONST(IORING_OP_TIMEOUT_REMOVE);
	CONST(IORING_OP_ACCEPT);
	CONST(IORING_OP_ASYNC_CANCEL);
	CONST(IORING_OP_LINK_TIMEOUT);
	CONST(IORING_OP_CONNECT);
	CONST(IORING_OP_FALLOCATE);
	CONST(IORING_OP_OPENAT);
	CONST(IORING_OP_CLOSE);
	CONST(IORING_OP_FILES_UPDATE);
	CONST(IORING_OP_STATX);
	CONST(IORING_OP_READ);
	CONST(IORING_OP_WRITE);
	CONST(IORING_OP_FADVISE);
	CONST(IORING_OP_MADVISE);
	CONST(IORING_OP_SEND);
	CONST(IORING_OP_RECV);
	CONST(IORING_OP_OPENAT2);
	CONST(IORING_OP_EPOLL_CTL);
	CONST(IORING_OP_SPLICE);
	CONST(IORING_OP_PROVIDE_BUFFERS);
	CONST(IORING_OP_REMOVE_BUFFERS);
	CONST(IORING_OP_TEE);
	CONST(IORING_OP_SHUTDOWN);
	CONST(IORING_OP_RENAMEAT);
	CONST(IORING_OP_UNLINKAT);
	CONST(IORING_OP_MKDIRAT);
	CONST(IORING_OP_SYMLINKAT);
	CONST(IORING_OP_LINKAT);
	CONST(IORING_OP_MSG_RING);
	CONST(IORING_OP_FSETXATTR);
	CONST(IORING_OP_SETXATTR);
	CONST(IORING_OP_FGETXATTR);
	CONST(IORING_OP_GETXATTR);
	CONST(IORING_OP_SOCKET);
	CONST(IORING_OP_URING_CMD);
	CONST(IORING_OP_SEND_ZC);
	CONST(IORING_OP_SENDMSG_ZC);
	CONST(IORING_OP_READ_MULTISHOT);
	CONST(IORING_OP_WAITID);
	CONST(IORING_OP_FUTEX_WAIT);
	CONST(IORING_OP_FUTEX_WAKE);
	CONST(IORING_OP_FUTEX_WAITV);
	CONST(IORING_OP_FIXED_FD_INSTALL);
	CONST(IORING_OP_LAST);

	CONST(IORING_URING_CMD_FIXED);
	CONST(IORING_URING_CMD_MASK);
	CONST(IORING_FSYNC_DATASYNC);
	CONST(IORING_TIMEOUT_ABS);
	CONST(IORING_TIMEOUT_UPDATE);
	CONST(IORING_TIMEOUT_BOOTTIME);
	CONST(IORING_TIMEOUT_REALTIME);
	CONST(IORING_LINK_TIMEOUT_UPDATE);
	CONST(IORING_TIMEOUT_ETIME_SUCCESS);
	CONST(IORING_TIMEOUT_MULTISHOT);
	CONST(IORING_TIMEOUT_CLOCK_MASK);
	CONST(IORING_TIMEOUT_UPDATE_MASK);
	CONST(SPLICE_F_FD_IN_FIXED);
	CONST(IORING_POLL_ADD_MULTI);
	CONST(IORING_POLL_UPDATE_EVENTS);
	CONST(IORING_POLL_UPDATE_USER_DATA);
	CONST(IORING_POLL_ADD_LEVEL);
	CONST(IORING_ASYNC_CANCEL_ALL);
	CONST(IORING_ASYNC_CANCEL_FD);
	CONST(IORING_ASYNC_CANCEL_ANY);
	CONST(IORING_ASYNC_CANCEL_FD_FIXED);
	CONST(IORING_ASYNC_CANCEL_USERDATA);
	CONST(IORING_ASYNC_CANCEL_OP);
	CONST(IORING_RECVSEND_POLL_FIRST);
	CONST(IORING_RECV_MULTISHOT);
	CONST(IORING_RECVSEND_FIXED_BUF);
	CONST(IORING_SEND_ZC_REPORT_USAGE);
	CONST(IORING_NOTIF_USAGE_ZC_COPIED);
	CONST(IORING_ACCEPT_MULTISHOT);
	CONST(IORING_MSG_DATA);
	CONST(IORING_MSG_SEND_FD);
	CONST(IORING_MSG_RING_CQE_SKIP);
	CONST(IORING_MSG_RING_FLAGS_PASS);
	CONST(IORING_FIXED_FD_NO_CLOEXEC);

	CONST(IORING_CQE_F_BUFFER);
	CONST(IORING_CQE_F_MORE);
	CONST(IORING_CQE_F_SOCK_NONEMPTY);
	CONST(IORING_CQE_F_NOTIF);
	CONST(IORING_CQE_BUFFER_SHIFT);

	CONST(IORING_OFF_SQ_RING);
	CONST(IORING_OFF_CQ_RING);
	CONST(IORING_OFF_SQES);
	CONST(IORING_OFF_PBUF_RING);
	CONST(IORING_OFF_PBUF_SHIFT);
	CONST(IORING_OFF_MMAP_MASK);

	CONST(IORING_SQ_NEED_WAKEUP);
	CONST(IORING_SQ_CQ_OVERFLOW);
	CONST(IORING_SQ_TASKRUN);
	CONST(IORING_CQ_EVENTFD_DISABLED);

	CONST(IORING_ENTER_GETEVENTS);
	CONST(IORING_ENTER_SQ_WAKEUP);
	CONST(IORING_ENTER_SQ_WAIT);
	CONST(IORING_ENTER_EXT_ARG);
	CONST(IORING_ENTER_REGISTERED_RING);

	CONST(IORING_FEAT_SINGLE_MMAP);
	CONST(IORING_FEAT_NODROP);
	CONST(IORING_FEAT_SUBMIT_STABLE);
	CONST(IORING_FEAT_RW_CUR_POS);
	CONST(IORING_FEAT_CUR_PERSONALITY);
	CONST(IORING_FEAT_FAST_POLL);
	CONST(IORING_FEAT_POLL_32BITS);
	CONST(IORING_FEAT_SQPOLL_NONFIXED);
	CONST(IORING_FEAT_EXT_ARG);
	CONST(IORING_FEAT_NATIVE_WORKERS);
	CONST(IORING_FEAT_RSRC_TAGS);
	CONST(IORING_FEAT_CQE_SKIP);
	CONST(IORING_FEAT_LINKED_FILE);
	CONST(IORING_FEAT_REG_REG_RING);

	CONST(IORING_REGISTER_BUFFERS);
	CONST(IORING_UNREGISTER_BUFFERS);
	CONST(IORING_REGISTER_FILES);
	CONST(IORING_UNREGISTER_FILES);
	CONST(IORING_REGISTER_EVENTFD);
	CONST(IORING_UNREGISTER_EVENTFD);
	CONST(IORING_REGISTER_FILES_UPDATE);
	CONST(IORING_REGISTER_EVENTFD_ASYNC);
	CONST(IORING_REGISTER_PROBE);
	CONST(IORING_REGISTER_PERSONALITY);
	CONST(IORING_UNREGISTER_PERSONALITY);
	CONST(IORING_REGISTER_RESTRICTIONS);
	CONST(IORING_REGISTER_ENABLE_RINGS);
	CONST(IORING_REGISTER_FILES2);
	CONST(IORING_REGISTER_FILES_UPDATE2);
	CONST(IORING_REGISTER_BUFFERS2);
	CONST(IORING_REGISTER_BUFFERS_UPDATE);
	CONST(IORING_REGISTER_IOWQ_AFF);
	CONST(IORING_UNREGISTER_IOWQ_AFF);
	CONST(IORING_REGISTER_IOWQ_MAX_WORKERS);
	CONST(IORING_REGISTER_RING_FDS);
	CONST(IORING_UNREGISTER_RING_FDS);
	CONST(IORING_REGISTER_PBUF_RING);
	CONST(IORING_UNREGISTER_PBUF_RING);
	CONST(IORING_REGISTER_SYNC_CANCEL);
	CONST(IORING_REGISTER_FILE_ALLOC_RANGE);
	CONST(IORING_REGISTER_PBUF_STATUS);
	CONST(IORING_REGISTER_LAST);
	CONST(IORING_REGISTER_USE_REGISTERED_RING);
	CONST(IO_WQ_BOUND);
	CONST(IO_WQ_UNBOUND);

	CONST(IORING_RSRC_REGISTER_SPARSE);
	CONST(IORING_REGISTER_FILES_SKIP);
	CONST(IO_URING_OP_SUPPORTED);
	CONST(IOU_PBUF_RING_MMAP);

	CONST(IORING_RESTRICTION_REGISTER_OP);
	CONST(IORING_RESTRICTION_SQE_OP);
	CONST(IORING_RESTRICTION_SQE_FLAGS_ALLOWED);
	CONST(IORING_RESTRICTION_SQE_FLAGS_REQUIRED);
	CONST(IORING_RESTRICTION_LAST);

	CONST(SOCKET_URING_OP_SIOCINQ);
	CONST(SOCKET_URING_OP_SIOCOUTQ);
	CONST(SOCKET_URING_OP_GETSOCKOPT);
	CONST(SOCKET_URING_OP_SETSOCKOPT);

	CONST(__NR_io_uring_setup);
	CONST(__NR_io_uring_enter);
	CONST(__NR_io_uring_register);

	printf("end;\n");
}

int main(void)
{
	printf("// Generated by Generate-LinuxApiLayout.sh from linux/io_uring.h of Linux %d.%d.%d\n",
	       LINUX_VERSION_CODE >> 16, (LINUX_VERSION_CODE >> 8) & 0xff, LINUX_VERSION_CODE & 0xff);
#if defined(__x86_64__)
	printf("// (built with gcc %s for x86-64). Do not edit: run the script again.\n\n", __VERSION__);
#elif defined(__aarch64__)
	printf("// (built with gcc %s for AArch64). Do not edit: run the script again.\n\n", __VERSION__);
#else
#error "x86-64 and AArch64 only"
#endif
	sizes();
	offsets();
	constants();
	return 0;
}
