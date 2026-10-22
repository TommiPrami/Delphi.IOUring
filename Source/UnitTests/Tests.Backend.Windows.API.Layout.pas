unit Tests.Backend.Windows.API.Layout;

{
  Record sizes and field offsets of Delphi.IOUring.Backend.Windows.API must be
  identical to the C structures (MSVC layout), on Win32 and on Win64.
  Expected values come from the C declarations in ioringapi.h / ntioring_x.h.
}

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TWindowsIoRingApiLayoutTests = class
  public
    [Test]
    procedure HIORING_IsPointerSized;
    [Test]
    procedure IORING_CREATE_FLAGS_Layout;
    [Test]
    procedure IORING_INFO_Layout;
    [Test]
    procedure IORING_CAPABILITIES_Layout;
    [Test]
    procedure IORING_HANDLE_REF_Layout;
    [Test]
    procedure IORING_REGISTERED_BUFFER_Layout;
    [Test]
    procedure IORING_BUFFER_REF_Layout;
    [Test]
    procedure IORING_BUFFER_INFO_Layout;
    [Test]
    procedure IORING_CQE_Layout;
    [Test]
    procedure FILE_SEGMENT_ELEMENT_Layout;

    [Test]
    procedure IoRingHandleRefFromHandle_SetsRawHandle;
    [Test]
    procedure IoRingHandleRefFromIndex_SetsRegisteredIndex;
    [Test]
    procedure IoRingBufferRefFromPointer_SetsRawAddress;
    [Test]
    procedure IoRingBufferRefFromIndexAndOffset_SetsRegisteredBuffer;
  end;

implementation

uses
  Winapi.Windows,
  Delphi.IOUring.Backend.Windows.API;

{$IFDEF CPUX64}
const
  POINTER_SIZE = 8;
{$ELSE}
const
  POINTER_SIZE = 4;
{$ENDIF}

procedure TWindowsIoRingApiLayoutTests.HIORING_IsPointerSized;
begin
  Assert.AreEqual(POINTER_SIZE, SizeOf(HIORING));
end;

procedure TWindowsIoRingApiLayoutTests.IORING_CREATE_FLAGS_Layout;
var
  LValue: IORING_CREATE_FLAGS;
begin
  Assert.AreEqual(8, SizeOf(IORING_CREATE_FLAGS));
  Assert.AreEqual(NativeInt(0), NativeInt(@LValue.Required) - NativeInt(@LValue));
  Assert.AreEqual(NativeInt(4), NativeInt(@LValue.Advisory) - NativeInt(@LValue));
end;

procedure TWindowsIoRingApiLayoutTests.IORING_INFO_Layout;
var
  LValue: IORING_INFO;
begin
  Assert.AreEqual(20, SizeOf(IORING_INFO));
  Assert.AreEqual(NativeInt(0), NativeInt(@LValue.IoRingVersion) - NativeInt(@LValue));
  Assert.AreEqual(NativeInt(4), NativeInt(@LValue.Flags) - NativeInt(@LValue));
  Assert.AreEqual(NativeInt(12), NativeInt(@LValue.SubmissionQueueSize) - NativeInt(@LValue));
  Assert.AreEqual(NativeInt(16), NativeInt(@LValue.CompletionQueueSize) - NativeInt(@LValue));
end;

procedure TWindowsIoRingApiLayoutTests.IORING_CAPABILITIES_Layout;
var
  LValue: IORING_CAPABILITIES;
begin
  Assert.AreEqual(16, SizeOf(IORING_CAPABILITIES));
  Assert.AreEqual(NativeInt(0), NativeInt(@LValue.MaxVersion) - NativeInt(@LValue));
  Assert.AreEqual(NativeInt(4), NativeInt(@LValue.MaxSubmissionQueueSize) - NativeInt(@LValue));
  Assert.AreEqual(NativeInt(8), NativeInt(@LValue.MaxCompletionQueueSize) - NativeInt(@LValue));
  Assert.AreEqual(NativeInt(12), NativeInt(@LValue.FeatureFlags) - NativeInt(@LValue));
end;

procedure TWindowsIoRingApiLayoutTests.IORING_HANDLE_REF_Layout;
var
  LValue: IORING_HANDLE_REF;
begin
  // Kind (4 bytes), then a union of HANDLE and UINT32 aligned to pointer size
  Assert.AreEqual(2 * POINTER_SIZE, SizeOf(IORING_HANDLE_REF));
  Assert.AreEqual(NativeInt(0), NativeInt(@LValue.Kind) - NativeInt(@LValue));
  Assert.AreEqual(NativeInt(POINTER_SIZE), NativeInt(@LValue.Handle) - NativeInt(@LValue));
  Assert.AreEqual(NativeInt(POINTER_SIZE), NativeInt(@LValue.Index) - NativeInt(@LValue));
end;

procedure TWindowsIoRingApiLayoutTests.IORING_REGISTERED_BUFFER_Layout;
var
  LValue: IORING_REGISTERED_BUFFER;
begin
  Assert.AreEqual(8, SizeOf(IORING_REGISTERED_BUFFER));
  Assert.AreEqual(NativeInt(0), NativeInt(@LValue.BufferIndex) - NativeInt(@LValue));
  Assert.AreEqual(NativeInt(4), NativeInt(@LValue.Offset) - NativeInt(@LValue));
end;

procedure TWindowsIoRingApiLayoutTests.IORING_BUFFER_REF_Layout;
var
  LValue: IORING_BUFFER_REF;
begin
  // Kind (4 bytes), then a union of void* and IORING_REGISTERED_BUFFER (8 bytes)
  // aligned to pointer size: Win32 4 + 8 = 12, Win64 8 + 8 = 16
  Assert.AreEqual(POINTER_SIZE + 8, SizeOf(IORING_BUFFER_REF));
  Assert.AreEqual(NativeInt(0), NativeInt(@LValue.Kind) - NativeInt(@LValue));
  Assert.AreEqual(NativeInt(POINTER_SIZE), NativeInt(@LValue.Address) - NativeInt(@LValue));
  Assert.AreEqual(NativeInt(POINTER_SIZE), NativeInt(@LValue.IndexAndOffset) - NativeInt(@LValue));
end;

procedure TWindowsIoRingApiLayoutTests.IORING_BUFFER_INFO_Layout;
var
  LValue: IORING_BUFFER_INFO;
begin
  Assert.AreEqual(2 * POINTER_SIZE, SizeOf(IORING_BUFFER_INFO));
  Assert.AreEqual(NativeInt(0), NativeInt(@LValue.Address) - NativeInt(@LValue));
  Assert.AreEqual(NativeInt(POINTER_SIZE), NativeInt(@LValue.Length) - NativeInt(@LValue));
end;

procedure TWindowsIoRingApiLayoutTests.IORING_CQE_Layout;
var
  LValue: IORING_CQE;
begin
  // UINT_PTR, HRESULT, ULONG_PTR: Win32 4 + 4 + 4 = 12, Win64 8 + 4 (+4 padding) + 8 = 24
  Assert.AreEqual(3 * POINTER_SIZE, SizeOf(IORING_CQE));
  Assert.AreEqual(NativeInt(0), NativeInt(@LValue.UserData) - NativeInt(@LValue));
  Assert.AreEqual(NativeInt(POINTER_SIZE), NativeInt(@LValue.ResultCode) - NativeInt(@LValue));
  Assert.AreEqual(NativeInt(2 * POINTER_SIZE), NativeInt(@LValue.Information) - NativeInt(@LValue));
end;

procedure TWindowsIoRingApiLayoutTests.FILE_SEGMENT_ELEMENT_Layout;
begin
  Assert.AreEqual(8, SizeOf(FILE_SEGMENT_ELEMENT));
end;

procedure TWindowsIoRingApiLayoutTests.IoRingHandleRefFromHandle_SetsRawHandle;
var
  LRef: IORING_HANDLE_REF;
begin
  LRef := IoRingHandleRefFromHandle(THandle($1234));

  Assert.AreEqual(Cardinal(IORING_REF_RAW), LRef.Kind);
  Assert.AreEqual(THandle($1234), LRef.Handle);
end;

procedure TWindowsIoRingApiLayoutTests.IoRingHandleRefFromIndex_SetsRegisteredIndex;
var
  LRef: IORING_HANDLE_REF;
begin
  LRef := IoRingHandleRefFromIndex(7);

  Assert.AreEqual(Cardinal(IORING_REF_REGISTERED), LRef.Kind);
  Assert.AreEqual(UInt32(7), LRef.Index);
  // The unused upper part of the union must be zero (Win64)
  Assert.AreEqual(THandle(7), LRef.Handle);
end;

procedure TWindowsIoRingApiLayoutTests.IoRingBufferRefFromPointer_SetsRawAddress;
var
  LRef: IORING_BUFFER_REF;
  LBuffer: array[0..15] of Byte;
begin
  LRef := IoRingBufferRefFromPointer(@LBuffer);

  Assert.AreEqual(Cardinal(IORING_REF_RAW), LRef.Kind);
  Assert.AreEqual(Pointer(@LBuffer), LRef.Address);
end;

procedure TWindowsIoRingApiLayoutTests.IoRingBufferRefFromIndexAndOffset_SetsRegisteredBuffer;
var
  LRef: IORING_BUFFER_REF;
begin
  LRef := IoRingBufferRefFromIndexAndOffset(3, 4096);

  Assert.AreEqual(Cardinal(IORING_REF_REGISTERED), LRef.Kind);
  Assert.AreEqual(UInt32(3), LRef.IndexAndOffset.BufferIndex);
  Assert.AreEqual(UInt32(4096), LRef.IndexAndOffset.Offset);
end;

initialization
  TDUnitX.RegisterTestFixture(TWindowsIoRingApiLayoutTests);

end.
