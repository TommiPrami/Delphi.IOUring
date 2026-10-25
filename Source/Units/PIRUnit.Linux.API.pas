unit PIRUnit.Linux.API;

{
  Complete translation of the Linux io_uring user API:
    linux/io_uring.h of Linux 6.8 (the header of Ubuntu 24.04 LTS,
    package linux-libc-dev), __kernel_timespec of linux/time_types.h and the
    three system call numbers of asm/unistd.h.

  This unit is standalone: it depends only on the RTL (BaseUnix, Syscall), has no initialization section, no global
  state and raises no exceptions. Other projects can use it without the rest of Pascal.IOUring.

  Free Pascal on Linux only, x86-64 and AArch64. The system call numbers are the same on both (io_uring came after the
  kernel gave all architectures one numbering). Tested on both (ARM64: in CI, Docs/Design.md §12.5).

  No C library and no liburing: io_uring_setup, io_uring_enter and
  io_uring_register call the kernel directly. Like liburing's, they return
  the kernel's result: >= 0 on success, -errno on failure (for example
  -ESysEINVAL = -22; the ESys* constants are in BaseUnix).

  Names are the original C names; P<name> is a pointer to <name>. C types: __u8 = Byte, __u16 = Word, __u32 = Cardinal,
  __s32 = Integer, __u64 and __aligned_u64 = UInt64, __s64 = Int64.

  How the C records are translated:
  - A C union is the variant part (case) of a record. Pascal allows a variant
    part only at the end of a record, so the fields that follow a union are
    in its last variant (all variants of these unions have the same size, or
    the last one is the largest, so the offsets are those of C). Every union
    member is reached by its C name: sqe.off, sqe.addr, sqe.rw_flags, ...
  - io_uring_sqe and io_uring_restriction are packed records. FPC aligns a
    variant part to its largest field, and the fields after the union are
    inside it; C aligns a union only to its own members. Example: the flags
    union of the SQE is at offset 28 in C, FPC would move it to 32 because
    user_data (8 bytes) follows it. C has no gaps in these two records, so
    packed gives the C offsets. (Found by the layout tests.)
  - io_sqring_offsets.array is &array (array is a reserved word).
  - C flexible arrays (x[]) add nothing to the size of the record:
    io_uring_cqe.big_cqe and io_uring_probe.ops are not fields here (a field
    would change SizeOf); they start right after the record. In
    io_uring_buf_ring, bufs shares the first 16 bytes with the tail, as in C;
    it is array[0..0]: index it with range checks off. io_uring_sqe.cmd
    (C: cmd[0]) is the last 16 bytes of the SQE; with IORING_SETUP_SQE128 the
    command data is 80 bytes and goes on into the next 64 bytes.

  "Linux x.y" says which kernel added an opcode or a setup flag. At run time ask the kernel itself:
  IORING_REGISTER_PROBE (which opcodes it has), io_uring_params.features (IORING_FEAT_*), and io_uring_setup refuses
  setup flags it does not know with -EINVAL.

  The C header is licensed (GPL-2.0 WITH Linux-syscall-note) OR MIT; this translation is under the MIT
  license of Pascal.IOUring.

  Documentation: the man pages io_uring(7), io_uring_setup(2), io_uring_enter(2) and io_uring_register(2);
  https://kernel.dk/io_uring.pdf
}

// Standalone on purpose: no PIRInclude.Compiler.inc, the needed switches are here.
{$IFNDEF FPC}
  {$MESSAGE FATAL 'PIRUnit.Linux.API is for Free Pascal on Linux.'}
{$ENDIF}
{$MODE DELPHI}
{$PACKRECORDS C}
{$IFNDEF LINUX}
  {$MESSAGE FATAL 'PIRUnit.Linux.API is for Linux.'}
{$ENDIF}
{$IF not (defined(CPUX86_64) or defined(CPUAARCH64))}
  {$MESSAGE FATAL 'PIRUnit.Linux.API is for x86-64 and AArch64.'}
{$ENDIF}

interface

{ ---------------------------------------------------------------------------- }
{ System calls (asm/unistd.h; the same numbers on x86-64 and AArch64)          }
{ ---------------------------------------------------------------------------- }

const
  __NR_io_uring_setup = 425;
  __NR_io_uring_enter = 426;
  __NR_io_uring_register = 427;

{ ---------------------------------------------------------------------------- }
{ Submission Queue Entry                                                       }
{ ---------------------------------------------------------------------------- }

type
  {
    IO submission data structure (Submission Queue Entry), 64 bytes; 128 bytes with IORING_SETUP_SQE128. Each "case
    Integer of" is one C union; the fields after it are in its last variant. Packed: without it FPC would move the
    unions (see the top of the unit); C has no gaps here either.
  }
  io_uring_sqe = packed record
    opcode: Byte;                   // type of operation for this sqe (IORING_OP_*)
    flags: Byte;                    // IOSQE_ flags
    ioprio: Word;                   // ioprio for the request
    fd: Integer;                    // file descriptor to do IO on
    case Integer of                 // union at offset 8
      0: (off: UInt64);             // offset into file
      1: (addr2: UInt64);
      2: (cmd_op: Cardinal;
          __pad1: Cardinal;
    case Integer of                 // union at offset 16
      0: (addr: UInt64);            // pointer to buffer or iovecs
      1: (splice_off_in: UInt64);
      2: (level: Cardinal;
          optname: Cardinal;
    len: Cardinal;                  // buffer size or number of iovecs
    case Integer of                 // union at offset 28: the flags of the operation
      0: (rw_flags: Cardinal);
      1: (fsync_flags: Cardinal);
      2: (poll_events: Word);       // compatibility
      3: (poll32_events: Cardinal); // word-reversed for BE
      4: (sync_range_flags: Cardinal);
      5: (msg_flags: Cardinal);
      6: (timeout_flags: Cardinal);
      7: (accept_flags: Cardinal);
      8: (cancel_flags: Cardinal);
      9: (open_flags: Cardinal);
      10: (statx_flags: Cardinal);
      11: (fadvise_advice: Cardinal);
      12: (splice_flags: Cardinal);
      13: (rename_flags: Cardinal);
      14: (unlink_flags: Cardinal);
      15: (hardlink_flags: Cardinal);
      16: (xattr_flags: Cardinal);
      17: (msg_ring_flags: Cardinal);
      18: (uring_cmd_flags: Cardinal);
      19: (waitid_flags: Cardinal);
      20: (futex_flags: Cardinal);
      21: (install_fd_flags: Cardinal;
    user_data: UInt64;              // data to be passed back at completion time
    case Integer of                 // union at offset 40 (packed in C; 2 bytes either way)
      0: (buf_index: Word);         // index into fixed buffers, if used
      1: (buf_group: Word;          // for grouped buffer selection
    personality: Word;              // personality to use, if used
    case Integer of                 // union at offset 44
      0: (splice_fd_in: Integer);
      1: (file_index: Cardinal);
      2: (optlen: Cardinal);
      3: (addr_len: Word;
          __pad3: array[0..0] of Word;
    case Integer of                 // union at offset 48
      0: (addr3: UInt64;
          __pad2: array[0..0] of UInt64);
      1: (optval: UInt64);
      // C: cmd[0]. With IORING_SETUP_SQE128, 80 bytes of command data
      2: (cmd: array[0..15] of Byte)
    )))));
  end;
  Pio_uring_sqe = ^io_uring_sqe;

const
  { If sqe.file_index is set to this for opcodes that make a new direct descriptor (openat, openat2, accept, ...),
    io_uring picks a free one and returns it in cqe.res (-ENFILE if there is none). }
  IORING_FILE_INDEX_ALLOC = $FFFFFFFF;  // ~0U

  IOSQE_FIXED_FILE_BIT = 0;
  IOSQE_IO_DRAIN_BIT = 1;
  IOSQE_IO_LINK_BIT = 2;
  IOSQE_IO_HARDLINK_BIT = 3;
  IOSQE_ASYNC_BIT = 4;
  IOSQE_BUFFER_SELECT_BIT = 5;
  IOSQE_CQE_SKIP_SUCCESS_BIT = 6;

  // sqe.flags
  IOSQE_FIXED_FILE = 1 shl IOSQE_FIXED_FILE_BIT;              // use fixed fileset
  IOSQE_IO_DRAIN = 1 shl IOSQE_IO_DRAIN_BIT;                  // issue after inflight IO
  IOSQE_IO_LINK = 1 shl IOSQE_IO_LINK_BIT;                    // links next sqe
  IOSQE_IO_HARDLINK = 1 shl IOSQE_IO_HARDLINK_BIT;            // like LINK, but stronger
  IOSQE_ASYNC = 1 shl IOSQE_ASYNC_BIT;                        // always go async
  IOSQE_BUFFER_SELECT = 1 shl IOSQE_BUFFER_SELECT_BIT;        // select buffer from sqe.buf_group
  IOSQE_CQE_SKIP_SUCCESS = 1 shl IOSQE_CQE_SKIP_SUCCESS_BIT;  // don't post CQE if request succeeded

{ ---------------------------------------------------------------------------- }
{ io_uring_setup flags (io_uring_params.flags)                                 }
{ ---------------------------------------------------------------------------- }

const
  IORING_SETUP_IOPOLL = 1 shl 0;          // io_context is polled (Linux 5.1)
  IORING_SETUP_SQPOLL = 1 shl 1;          // SQ poll thread (Linux 5.1)
  IORING_SETUP_SQ_AFF = 1 shl 2;          // sq_thread_cpu is valid (Linux 5.1)
  IORING_SETUP_CQSIZE = 1 shl 3;          // app defines CQ size (Linux 5.5)
  IORING_SETUP_CLAMP = 1 shl 4;           // clamp SQ/CQ ring sizes (Linux 5.6)
  IORING_SETUP_ATTACH_WQ = 1 shl 5;       // attach to existing wq (Linux 5.6)
  IORING_SETUP_R_DISABLED = 1 shl 6;      // start with ring disabled (Linux 5.10)
  IORING_SETUP_SUBMIT_ALL = 1 shl 7;      // continue submit on error (Linux 5.18)
  { Cooperative task running: work for completed requests is done when the task enters the kernel anyway, instead of
    interrupting it (saves an inter-processor interrupt). (Linux 5.19) }
  IORING_SETUP_COOP_TASKRUN = 1 shl 8;
  { With COOP_TASKRUN: IORING_SQ_TASKRUN is set in the SQ ring flags when task work is waiting and a kernel entry is
    needed to run it. (Linux 5.19) }
  IORING_SETUP_TASKRUN_FLAG = 1 shl 9;
  IORING_SETUP_SQE128 = 1 shl 10;         // SQEs are 128 byte (Linux 5.19)
  IORING_SETUP_CQE32 = 1 shl 11;          // CQEs are 32 byte (Linux 5.19)
  // Only one task is allowed to submit requests (Linux 6.0)
  IORING_SETUP_SINGLE_ISSUER = 1 shl 12;
  { Defer running task work to get events: run it just before it is needed, not whenever the task
    enters the kernel (Linux 6.1) }
  IORING_SETUP_DEFER_TASKRUN = 1 shl 13;
  // Application provides the memory for the rings (Linux 6.5)
  IORING_SETUP_NO_MMAP = 1 shl 14;
  { Register the ring fd in itself for use with IORING_REGISTER_USE_REGISTERED_RING; return a registered fd index
    rather than an fd (Linux 6.5) }
  IORING_SETUP_REGISTERED_FD_ONLY = 1 shl 15;
  // Removes indirection through the SQ index array (Linux 6.6)
  IORING_SETUP_NO_SQARRAY = 1 shl 16;

{ ---------------------------------------------------------------------------- }
{ Opcodes (enum io_uring_op; sqe.opcode is a Byte)                             }
{ ---------------------------------------------------------------------------- }

type
  io_uring_op = Cardinal;

const
  IORING_OP_NOP = 0;                // Linux 5.1
  IORING_OP_READV = 1;              // Linux 5.1
  IORING_OP_WRITEV = 2;             // Linux 5.1
  IORING_OP_FSYNC = 3;              // Linux 5.1
  IORING_OP_READ_FIXED = 4;         // Linux 5.1
  IORING_OP_WRITE_FIXED = 5;        // Linux 5.1
  IORING_OP_POLL_ADD = 6;           // Linux 5.1
  IORING_OP_POLL_REMOVE = 7;        // Linux 5.1
  IORING_OP_SYNC_FILE_RANGE = 8;    // Linux 5.2
  IORING_OP_SENDMSG = 9;            // Linux 5.3
  IORING_OP_RECVMSG = 10;           // Linux 5.3
  IORING_OP_TIMEOUT = 11;           // Linux 5.4
  IORING_OP_TIMEOUT_REMOVE = 12;    // Linux 5.5
  IORING_OP_ACCEPT = 13;            // Linux 5.5
  IORING_OP_ASYNC_CANCEL = 14;      // Linux 5.5
  IORING_OP_LINK_TIMEOUT = 15;      // Linux 5.5
  IORING_OP_CONNECT = 16;           // Linux 5.5
  IORING_OP_FALLOCATE = 17;         // Linux 5.6
  IORING_OP_OPENAT = 18;            // Linux 5.6
  IORING_OP_CLOSE = 19;             // Linux 5.6
  IORING_OP_FILES_UPDATE = 20;      // Linux 5.6
  IORING_OP_STATX = 21;             // Linux 5.6
  IORING_OP_READ = 22;              // Linux 5.6
  IORING_OP_WRITE = 23;             // Linux 5.6
  IORING_OP_FADVISE = 24;           // Linux 5.6
  IORING_OP_MADVISE = 25;           // Linux 5.6
  IORING_OP_SEND = 26;              // Linux 5.6
  IORING_OP_RECV = 27;              // Linux 5.6
  IORING_OP_OPENAT2 = 28;           // Linux 5.6
  IORING_OP_EPOLL_CTL = 29;         // Linux 5.6
  IORING_OP_SPLICE = 30;            // Linux 5.7
  IORING_OP_PROVIDE_BUFFERS = 31;   // Linux 5.7
  IORING_OP_REMOVE_BUFFERS = 32;    // Linux 5.7
  IORING_OP_TEE = 33;               // Linux 5.8
  IORING_OP_SHUTDOWN = 34;          // Linux 5.11
  IORING_OP_RENAMEAT = 35;          // Linux 5.11
  IORING_OP_UNLINKAT = 36;          // Linux 5.11
  IORING_OP_MKDIRAT = 37;           // Linux 5.15
  IORING_OP_SYMLINKAT = 38;         // Linux 5.15
  IORING_OP_LINKAT = 39;            // Linux 5.15
  IORING_OP_MSG_RING = 40;          // Linux 5.18
  IORING_OP_FSETXATTR = 41;         // Linux 5.19
  IORING_OP_SETXATTR = 42;          // Linux 5.19
  IORING_OP_FGETXATTR = 43;         // Linux 5.19
  IORING_OP_GETXATTR = 44;          // Linux 5.19
  IORING_OP_SOCKET = 45;            // Linux 5.19
  IORING_OP_URING_CMD = 46;         // Linux 5.19
  IORING_OP_SEND_ZC = 47;           // Linux 6.0
  IORING_OP_SENDMSG_ZC = 48;        // Linux 6.1
  IORING_OP_READ_MULTISHOT = 49;    // Linux 6.7
  IORING_OP_WAITID = 50;            // Linux 6.7
  IORING_OP_FUTEX_WAIT = 51;        // Linux 6.7
  IORING_OP_FUTEX_WAKE = 52;        // Linux 6.7
  IORING_OP_FUTEX_WAITV = 53;       // Linux 6.7
  IORING_OP_FIXED_FD_INSTALL = 54;  // Linux 6.8
  // this goes last, obviously (in the 6.8 header; newer kernels have more)
  IORING_OP_LAST = 55;

{ ---------------------------------------------------------------------------- }
{ Flags of the operations (the flags union of the SQE, and others)             }
{ ---------------------------------------------------------------------------- }

const
  { sqe.uring_cmd_flags (the top 8 bits are not for user space). IORING_URING_CMD_FIXED: use a registered
    buffer; set sqe.buf_index too. }
  IORING_URING_CMD_FIXED = 1 shl 0;
  IORING_URING_CMD_MASK = IORING_URING_CMD_FIXED;

  // sqe.fsync_flags
  IORING_FSYNC_DATASYNC = 1 shl 0;

  // sqe.timeout_flags
  IORING_TIMEOUT_ABS = 1 shl 0;
  IORING_TIMEOUT_UPDATE = 1 shl 1;
  IORING_TIMEOUT_BOOTTIME = 1 shl 2;
  IORING_TIMEOUT_REALTIME = 1 shl 3;
  IORING_LINK_TIMEOUT_UPDATE = 1 shl 4;
  IORING_TIMEOUT_ETIME_SUCCESS = 1 shl 5;
  IORING_TIMEOUT_MULTISHOT = 1 shl 6;
  IORING_TIMEOUT_CLOCK_MASK = IORING_TIMEOUT_BOOTTIME or IORING_TIMEOUT_REALTIME;
  IORING_TIMEOUT_UPDATE_MASK = IORING_TIMEOUT_UPDATE or IORING_LINK_TIMEOUT_UPDATE;

  // sqe.splice_flags: extends the flags of splice(2)
  SPLICE_F_FD_IN_FIXED = 1 shl 31;  // the last bit of __u32

  {
    POLL_ADD flags. sqe.poll_events holds the poll events, so these command
    flags are in sqe.len.
    IORING_POLL_ADD_MULTI: multishot poll; sets IORING_CQE_F_MORE while the
      poll handler goes on reporting CQEs for the same SQE.
    IORING_POLL_UPDATE_*: update an existing poll request, matching sqe.addr
      as the old user_data.
    IORING_POLL_ADD_LEVEL: level triggered poll.
  }
  IORING_POLL_ADD_MULTI = 1 shl 0;
  IORING_POLL_UPDATE_EVENTS = 1 shl 1;
  IORING_POLL_UPDATE_USER_DATA = 1 shl 2;
  IORING_POLL_ADD_LEVEL = 1 shl 3;

  // ASYNC_CANCEL flags (sqe.cancel_flags)
  IORING_ASYNC_CANCEL_ALL = 1 shl 0;       // cancel all requests that match the given key
  IORING_ASYNC_CANCEL_FD = 1 shl 1;        // key off 'fd' for cancelation rather than user_data
  IORING_ASYNC_CANCEL_ANY = 1 shl 2;       // match any request
  IORING_ASYNC_CANCEL_FD_FIXED = 1 shl 3;  // 'fd' passed in is a fixed descriptor
  IORING_ASYNC_CANCEL_USERDATA = 1 shl 4;  // match on user_data, default for no other key
  IORING_ASYNC_CANCEL_OP = 1 shl 5;        // match request based on opcode

  {
    send/sendmsg and recv/recvmsg flags (sqe.ioprio)
    IORING_RECVSEND_POLL_FIRST: arm poll first, without the first attempt to
      send or receive.
    IORING_RECV_MULTISHOT: multishot recv; sets IORING_CQE_F_MORE while the
      handler goes on reporting CQEs for the same SQE.
    IORING_RECVSEND_FIXED_BUF: use a registered buffer, index in sqe.buf_index.
    IORING_SEND_ZC_REPORT_USAGE: SEND[MSG]_ZC reports in cqe.res of the
      IORING_CQE_F_NOTIF CQE whether zero copy was possible: 0 if it was,
      IORING_NOTIF_USAGE_ZC_COPIED if the data was copied (at least partly).
  }
  IORING_RECVSEND_POLL_FIRST = 1 shl 0;
  IORING_RECV_MULTISHOT = 1 shl 1;
  IORING_RECVSEND_FIXED_BUF = 1 shl 2;
  IORING_SEND_ZC_REPORT_USAGE = 1 shl 3;

  { cqe.res of the IORING_CQE_F_NOTIF CQE with IORING_SEND_ZC_REPORT_USAGE. A flag: the other bits of cqe.res are
    reserved. cqe.res is an Integer, so test Cardinal(cqe.res) and IORING_NOTIF_USAGE_ZC_COPIED. }
  IORING_NOTIF_USAGE_ZC_COPIED = 1 shl 31;

  // accept flags (sqe.ioprio)
  IORING_ACCEPT_MULTISHOT = 1 shl 0;

  // IORING_OP_MSG_RING command types (sqe.addr)
  IORING_MSG_DATA = 0;     // pass sqe.len as 'res' and off as user_data
  IORING_MSG_SEND_FD = 1;  // send a registered fd to another ring

  // IORING_OP_MSG_RING flags (sqe.msg_ring_flags)
  IORING_MSG_RING_CQE_SKIP = 1 shl 0;    // no CQE to the target ring (not for IORING_MSG_DATA)
  IORING_MSG_RING_FLAGS_PASS = 1 shl 1;  // pass the flags from sqe.file_index to cqe.flags

  // IORING_OP_FIXED_FD_INSTALL flags (sqe.install_fd_flags)
  IORING_FIXED_FD_NO_CLOEXEC = 1 shl 0;  // don't mark the fd as O_CLOEXEC

{ ---------------------------------------------------------------------------- }
{ Completion Queue Entry                                                       }
{ ---------------------------------------------------------------------------- }

type
  { IO completion data structure (Completion Queue Entry), 16 bytes. C: __u64 big_cqe[] at the end. With
    IORING_SETUP_CQE32 each CQE is 32 bytes: big_cqe is the 16 bytes right after this record. }
  io_uring_cqe = record
    user_data: UInt64;  // sqe.user_data passed back
    res: Integer;       // result code for this event
    flags: Cardinal;    // IORING_CQE_F_*
  end;
  Pio_uring_cqe = ^io_uring_cqe;

const
  // cqe.flags
  IORING_CQE_F_BUFFER = 1 shl 0;         // the upper 16 bits are the buffer ID
  IORING_CQE_F_MORE = 1 shl 1;           // parent SQE will generate more CQE entries
  IORING_CQE_F_SOCK_NONEMPTY = 1 shl 2;  // more data to read after socket recv
  IORING_CQE_F_NOTIF = 1 shl 3;          // notification CQE (tells it apart from sends)

  IORING_CQE_BUFFER_SHIFT = 16;

{ ---------------------------------------------------------------------------- }
{ Ring memory (mmap offsets and the offsets records)                           }
{ ---------------------------------------------------------------------------- }

const
  // Magic offsets for the application to mmap the data it needs
  IORING_OFF_SQ_RING = 0;
  IORING_OFF_CQ_RING = $8000000;
  IORING_OFF_SQES = $10000000;
  IORING_OFF_PBUF_RING = $80000000;
  IORING_OFF_PBUF_SHIFT = 16;
  IORING_OFF_MMAP_MASK = $F8000000;

type
  // Filled with the offsets for mmap(2): byte offsets into the SQ ring memory
  io_sqring_offsets = record
    head: Cardinal;
    tail: Cardinal;
    ring_mask: Cardinal;
    ring_entries: Cardinal;
    flags: Cardinal;
    dropped: Cardinal;
    &array: Cardinal;
    resv1: Cardinal;
    user_addr: UInt64;
  end;
  Pio_sqring_offsets = ^io_sqring_offsets;

const
  // sq_ring.flags
  IORING_SQ_NEED_WAKEUP = 1 shl 0;  // needs io_uring_enter wakeup
  IORING_SQ_CQ_OVERFLOW = 1 shl 1;  // CQ ring is overflown
  IORING_SQ_TASKRUN = 1 shl 2;      // task should enter the kernel

type
  // Byte offsets into the CQ ring memory
  io_cqring_offsets = record
    head: Cardinal;
    tail: Cardinal;
    ring_mask: Cardinal;
    ring_entries: Cardinal;
    overflow: Cardinal;
    cqes: Cardinal;
    flags: Cardinal;
    resv1: Cardinal;
    user_addr: UInt64;
  end;
  Pio_cqring_offsets = ^io_cqring_offsets;

const
  // cq_ring.flags
  IORING_CQ_EVENTFD_DISABLED = 1 shl 0;  // disable eventfd notifications

{ ---------------------------------------------------------------------------- }
{ io_uring_enter flags                                                         }
{ ---------------------------------------------------------------------------- }

const
  IORING_ENTER_GETEVENTS = 1 shl 0;
  IORING_ENTER_SQ_WAKEUP = 1 shl 1;
  IORING_ENTER_SQ_WAIT = 1 shl 2;
  IORING_ENTER_EXT_ARG = 1 shl 3;
  IORING_ENTER_REGISTERED_RING = 1 shl 4;

{ ---------------------------------------------------------------------------- }
{ io_uring_setup parameters and features                                       }
{ ---------------------------------------------------------------------------- }

type
  // Passed in for io_uring_setup(2). Copied back with updated info on success
  io_uring_params = record
    sq_entries: Cardinal;
    cq_entries: Cardinal;
    flags: Cardinal;          // IORING_SETUP_*
    sq_thread_cpu: Cardinal;
    sq_thread_idle: Cardinal;
    features: Cardinal;       // IORING_FEAT_*, set by the kernel
    wq_fd: Cardinal;
    resv: array[0..2] of Cardinal;
    sq_off: io_sqring_offsets;
    cq_off: io_cqring_offsets;
  end;
  Pio_uring_params = ^io_uring_params;

const
  // io_uring_params.features flags
  IORING_FEAT_SINGLE_MMAP = 1 shl 0;
  IORING_FEAT_NODROP = 1 shl 1;
  IORING_FEAT_SUBMIT_STABLE = 1 shl 2;
  IORING_FEAT_RW_CUR_POS = 1 shl 3;
  IORING_FEAT_CUR_PERSONALITY = 1 shl 4;
  IORING_FEAT_FAST_POLL = 1 shl 5;
  IORING_FEAT_POLL_32BITS = 1 shl 6;
  IORING_FEAT_SQPOLL_NONFIXED = 1 shl 7;
  IORING_FEAT_EXT_ARG = 1 shl 8;
  IORING_FEAT_NATIVE_WORKERS = 1 shl 9;
  IORING_FEAT_RSRC_TAGS = 1 shl 10;
  IORING_FEAT_CQE_SKIP = 1 shl 11;
  IORING_FEAT_LINKED_FILE = 1 shl 12;
  IORING_FEAT_REG_REG_RING = 1 shl 13;

{ ---------------------------------------------------------------------------- }
{ io_uring_register opcodes and arguments                                      }
{ ---------------------------------------------------------------------------- }

const
  IORING_REGISTER_BUFFERS = 0;
  IORING_UNREGISTER_BUFFERS = 1;
  IORING_REGISTER_FILES = 2;
  IORING_UNREGISTER_FILES = 3;
  IORING_REGISTER_EVENTFD = 4;
  IORING_UNREGISTER_EVENTFD = 5;
  IORING_REGISTER_FILES_UPDATE = 6;
  IORING_REGISTER_EVENTFD_ASYNC = 7;
  IORING_REGISTER_PROBE = 8;
  IORING_REGISTER_PERSONALITY = 9;
  IORING_UNREGISTER_PERSONALITY = 10;
  IORING_REGISTER_RESTRICTIONS = 11;
  IORING_REGISTER_ENABLE_RINGS = 12;

  // extended with tagging
  IORING_REGISTER_FILES2 = 13;
  IORING_REGISTER_FILES_UPDATE2 = 14;
  IORING_REGISTER_BUFFERS2 = 15;
  IORING_REGISTER_BUFFERS_UPDATE = 16;

  // set/clear io-wq thread affinities
  IORING_REGISTER_IOWQ_AFF = 17;
  IORING_UNREGISTER_IOWQ_AFF = 18;

  // set/get max number of io-wq workers
  IORING_REGISTER_IOWQ_MAX_WORKERS = 19;

  // register/unregister io_uring fd with the ring
  IORING_REGISTER_RING_FDS = 20;
  IORING_UNREGISTER_RING_FDS = 21;

  // register ring based provide buffer group
  IORING_REGISTER_PBUF_RING = 22;
  IORING_UNREGISTER_PBUF_RING = 23;

  // sync cancelation API
  IORING_REGISTER_SYNC_CANCEL = 24;

  // register a range of fixed file slots for automatic slot allocation
  IORING_REGISTER_FILE_ALLOC_RANGE = 25;

  // return status information for a buffer group
  IORING_REGISTER_PBUF_STATUS = 26;

  // this goes last (in the 6.8 header; newer kernels have more)
  IORING_REGISTER_LAST = 27;

  // flag added to the opcode to use a registered ring fd
  IORING_REGISTER_USE_REGISTERED_RING = 1 shl 31;

  // io-wq worker categories
  IO_WQ_BOUND = 0;
  IO_WQ_UNBOUND = 1;

type
  // deprecated, see io_uring_rsrc_update
  io_uring_files_update = record
    offset: Cardinal;
    resv: Cardinal;
    fds: UInt64;  // C: __aligned_u64 /* __s32 * */
  end;
  Pio_uring_files_update = ^io_uring_files_update;

const
  { Register a fully sparse file space, rather than pass in an array of all
    -1 file descriptors (io_uring_rsrc_register.flags) }
  IORING_RSRC_REGISTER_SPARSE = 1 shl 0;

type
  io_uring_rsrc_register = record
    nr: Cardinal;
    flags: Cardinal;
    resv2: UInt64;
    data: UInt64;
    tags: UInt64;
  end;
  Pio_uring_rsrc_register = ^io_uring_rsrc_register;

  io_uring_rsrc_update = record
    offset: Cardinal;
    resv: Cardinal;
    data: UInt64;
  end;
  Pio_uring_rsrc_update = ^io_uring_rsrc_update;

  io_uring_rsrc_update2 = record
    offset: Cardinal;
    resv: Cardinal;
    data: UInt64;
    tags: UInt64;
    nr: Cardinal;
    resv2: Cardinal;
  end;
  Pio_uring_rsrc_update2 = ^io_uring_rsrc_update2;

const
  // Skip updating fd indexes set to this value in the fd table
  IORING_REGISTER_FILES_SKIP = -2;

  // io_uring_probe_op.flags
  IO_URING_OP_SUPPORTED = 1 shl 0;

type
  io_uring_probe_op = record
    op: Byte;
    resv: Byte;
    flags: Word;  // IO_URING_OP_* flags
    resv2: Cardinal;
  end;
  Pio_uring_probe_op = ^io_uring_probe_op;

  { C: struct io_uring_probe_op ops[] at the end. The ops start right after this record: Pio_uring_probe_op(PByte(probe)
    + SizeOf(io_uring_probe)). Give the kernel room for them: IORING_REGISTER_PROBE with nr_args ops. }
  io_uring_probe = record
    last_op: Byte;  // last opcode supported
    ops_len: Byte;  // length of ops[] array below
    resv: Word;
    resv2: array[0..2] of Cardinal;
  end;
  Pio_uring_probe = ^io_uring_probe;

  // Packed, like io_uring_sqe: without it FPC would put the union at offset 4
  io_uring_restriction = packed record
    opcode: Word;               // IORING_RESTRICTION_*
    case Integer of             // union at offset 2
      0: (register_op: Byte);   // IORING_RESTRICTION_REGISTER_OP
      1: (sqe_op: Byte);        // IORING_RESTRICTION_SQE_OP
      2: (sqe_flags: Byte;      // IORING_RESTRICTION_SQE_FLAGS_*
    resv: Byte;
    resv2: array[0..2] of Cardinal);
  end;
  Pio_uring_restriction = ^io_uring_restriction;

  io_uring_buf = record
    addr: UInt64;
    len: Cardinal;
    bid: Word;
    resv: Word;
  end;
  Pio_uring_buf = ^io_uring_buf;

  { The ring of a provided buffer group. To avoid spilling into more pages than needed, the ring tail is laid over the
    resv field of bufs[0]. bufs is a flexible array: index it with range checks off. }
  io_uring_buf_ring = record
    case Integer of
      0: (resv1: UInt64;
          resv2: Cardinal;
          resv3: Word;
          tail: Word);
      1: (bufs: array[0..0] of io_uring_buf);
  end;
  Pio_uring_buf_ring = ^io_uring_buf_ring;

const
  {
    Flags for IORING_REGISTER_PBUF_RING (io_uring_buf_reg.flags). IOU_PBUF_RING_MMAP: the kernel allocates the memory
    for the ring. Leave io_uring_buf_reg.ring_addr empty and then mmap(2) the ring with the offset IORING_OFF_PBUF_RING
    or (bgid shl IORING_OFF_PBUF_SHIFT).
  }
  IOU_PBUF_RING_MMAP = 1;

type
  // argument for IORING_(UN)REGISTER_PBUF_RING
  io_uring_buf_reg = record
    ring_addr: UInt64;
    ring_entries: Cardinal;
    bgid: Word;
    flags: Word;
    resv: array[0..2] of UInt64;
  end;
  Pio_uring_buf_reg = ^io_uring_buf_reg;

  // argument for IORING_REGISTER_PBUF_STATUS
  io_uring_buf_status = record
    buf_group: Cardinal;  // input
    head: Cardinal;       // output
    resv: array[0..7] of Cardinal;
  end;
  Pio_uring_buf_status = ^io_uring_buf_status;

const
  // io_uring_restriction.opcode values
  IORING_RESTRICTION_REGISTER_OP = 0;         // allow an io_uring_register(2) opcode
  IORING_RESTRICTION_SQE_OP = 1;              // allow an sqe opcode
  IORING_RESTRICTION_SQE_FLAGS_ALLOWED = 2;   // allow sqe flags
  IORING_RESTRICTION_SQE_FLAGS_REQUIRED = 3;  // require sqe flags (on each submission)
  IORING_RESTRICTION_LAST = 4;

type
  // linux/time_types.h. The time for IORING_OP_TIMEOUT, io_uring_getevents_arg and io_uring_sync_cancel_reg.
  __kernel_timespec = record
    tv_sec: Int64;   // __kernel_time64_t
    tv_nsec: Int64;  // long long
  end;
  P__kernel_timespec = ^__kernel_timespec;

  // The argument of io_uring_enter2 with IORING_ENTER_EXT_ARG
  io_uring_getevents_arg = record
    sigmask: UInt64;
    sigmask_sz: Cardinal;
    pad: Cardinal;
    ts: UInt64;
  end;
  Pio_uring_getevents_arg = ^io_uring_getevents_arg;

  // Argument for IORING_REGISTER_SYNC_CANCEL
  io_uring_sync_cancel_reg = record
    addr: UInt64;
    fd: Integer;
    flags: Cardinal;
    timeout: __kernel_timespec;
    opcode: Byte;
    pad: array[0..6] of Byte;
    pad2: array[0..2] of UInt64;
  end;
  Pio_uring_sync_cancel_reg = ^io_uring_sync_cancel_reg;

  // Argument for IORING_REGISTER_FILE_ALLOC_RANGE. The range is [off, off + len)
  io_uring_file_index_range = record
    off: Cardinal;
    len: Cardinal;
    resv: UInt64;
  end;
  Pio_uring_file_index_range = ^io_uring_file_index_range;

  io_uring_recvmsg_out = record
    namelen: Cardinal;
    controllen: Cardinal;
    payloadlen: Cardinal;
    flags: Cardinal;
  end;
  Pio_uring_recvmsg_out = ^io_uring_recvmsg_out;

const
  // Argument for IORING_OP_URING_CMD when the file is a socket (sqe.cmd_op)
  SOCKET_URING_OP_SIOCINQ = 0;
  SOCKET_URING_OP_SIOCOUTQ = 1;
  SOCKET_URING_OP_GETSOCKOPT = 2;
  SOCKET_URING_OP_SETSOCKOPT = 3;

  { ---------------------------------------------------------------------------- }
  { System call wrappers. Result: >= 0 on success, -errno on failure.            }
  { ---------------------------------------------------------------------------- }

  { Creates a ring with (at least) entries SQ entries. p: in: flags and the other inputs; out: the sizes, features and
    ring offsets. Result: the ring's file descriptor (close it with FpClose). }
  function io_uring_setup(entries: Cardinal; p: Pio_uring_params): Integer;

  { Submits to_submit SQEs and/or waits for min_complete CQEs (IORING_ENTER_GETEVENTS). sig: a signal mask (sigset_t) to
    use while waiting, or nil. Result: the number of SQEs submitted. }
  function io_uring_enter(fd: Cardinal; to_submit, min_complete, flags: Cardinal; sig: Pointer): Integer;

  { io_uring_enter with the size of arg: with IORING_ENTER_EXT_ARG, arg is a Pio_uring_getevents_arg and argsz =
    SizeOf(io_uring_getevents_arg); otherwise arg is a sigset_t and argsz its size (8). }
  function io_uring_enter2(fd: Cardinal; to_submit, min_complete, flags: Cardinal; arg: Pointer;
    argsz: NativeUInt): Integer;

  { Registers or unregisters files, buffers, ... (IORING_REGISTER_*), or asks the kernel (IORING_REGISTER_PROBE).
    nr_args: the number of items arg points to. }
  function io_uring_register(fd: Cardinal; opcode: Cardinal; arg: Pointer; nr_args: Cardinal): Integer;

implementation

uses
  BaseUnix, Syscall;

const
  // The kernel's sigset_t: 64 signals (_NSIG / 8)
  KERNEL_SIGSET_SIZE = 8;

{ Pointers go to the kernel as system call arguments (TSysParam). The unit is for 64-bit CPUs only, where both are 64
  bits: no hint "Conversion between ordinals and pointers is not portable". }
{$WARN 4055 OFF}

{ FPC's system call functions return -1 and set errno on failure; the kernel itself returns -errno. Give back the
  kernel's form, as liburing does. }
function KernelResult(const AResult: TSysResult): Integer; inline;
begin
  if AResult = -1 then
    Result := -fpgeterrno
  else
    Result := Integer(AResult);
end;

function io_uring_setup(entries: Cardinal; p: Pio_uring_params): Integer;
begin
  Result := KernelResult(do_SysCall(__NR_io_uring_setup, TSysParam(entries), TSysParam(p)));
end;

function io_uring_enter(fd: Cardinal; to_submit, min_complete, flags: Cardinal; sig: Pointer): Integer;
begin
  Result := io_uring_enter2(fd, to_submit, min_complete, flags, sig, KERNEL_SIGSET_SIZE);
end;

function io_uring_enter2(fd: Cardinal; to_submit, min_complete, flags: Cardinal; arg: Pointer;
  argsz: NativeUInt): Integer;
begin
  Result := KernelResult(do_SysCall(__NR_io_uring_enter, TSysParam(fd), TSysParam(to_submit), TSysParam(min_complete),
    TSysParam(flags), TSysParam(arg), TSysParam(argsz)));
end;

function io_uring_register(fd: Cardinal; opcode: Cardinal; arg: Pointer; nr_args: Cardinal): Integer;
begin
  Result := KernelResult(do_SysCall(__NR_io_uring_register, TSysParam(fd), TSysParam(opcode), TSysParam(arg),
    TSysParam(nr_args)));
end;

end.
