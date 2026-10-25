unit PIRUnit.Windows.API.Layout.Tests;

{
  Record sizes and field offsets of PIRUnit.Windows.API must be
  identical to the C structures (MSVC layout), on Win32 and on Win64.
  Expected values come from the C declarations in ioringapi.h / ntioring_x.h.
}

{$I PIRInclude.Compiler.inc}

interface

uses
  PIRUnit.Test.Support;

type
  TWindowsIoRingApiLayoutTests = class(TIORingTestCase)
  private
    procedure CheckOffset(const AName: string; const AExpected: NativeInt; const AField, ARecord: Pointer);
  published
    procedure HIORING_IsPointerSized;
    procedure IORING_CREATE_FLAGS_Layout;
    procedure IORING_INFO_Layout;
    procedure IORING_CAPABILITIES_Layout;
    procedure IORING_HANDLE_REF_Layout;
    procedure IORING_REGISTERED_BUFFER_Layout;
    procedure IORING_BUFFER_REF_Layout;
    procedure IORING_BUFFER_INFO_Layout;
    procedure IORING_CQE_Layout;
    procedure FILE_SEGMENT_ELEMENT_Layout;
    procedure IoRingHandleRefFromHandle_SetsRawHandle;
    procedure IoRingHandleRefFromIndex_SetsRegisteredIndex;
    procedure IoRingBufferRefFromPointer_SetsRawAddress;
    procedure IoRingBufferRefFromIndexAndOffset_SetsRegisteredBuffer;
  end;

implementation

uses
{$IFDEF FPC}
  Windows,
{$ELSE}
  Winapi.Windows,
{$ENDIF}
  PIRUnit.Windows.API;

{$IFDEF CPUX64}
const
  POINTER_SIZE = 8;
{$ELSE}
const
  POINTER_SIZE = 4;
{$ENDIF}

procedure TWindowsIoRingApiLayoutTests.CheckOffset(const AName: string; const AExpected: NativeInt;
  const AField, ARecord: Pointer);
begin
  AssertEquals(AName, Int64(AExpected), Int64(NativeUInt(AField) - NativeUInt(ARecord)));
end;

procedure TWindowsIoRingApiLayoutTests.HIORING_IsPointerSized;
begin
  AssertEquals(Int64(POINTER_SIZE), Int64(SizeOf(HIORING)));
end;

procedure TWindowsIoRingApiLayoutTests.IORING_CREATE_FLAGS_Layout;
var
  LValue: IORING_CREATE_FLAGS;
begin
  AssertEquals('SizeOf', Int64(8), Int64(SizeOf(IORING_CREATE_FLAGS)));
  CheckOffset('Required', 0, @LValue.Required, @LValue);
  CheckOffset('Advisory', 4, @LValue.Advisory, @LValue);
end;

procedure TWindowsIoRingApiLayoutTests.IORING_INFO_Layout;
var
  LValue: IORING_INFO;
begin
  AssertEquals('SizeOf', Int64(20), Int64(SizeOf(IORING_INFO)));
  CheckOffset('IoRingVersion', 0, @LValue.IoRingVersion, @LValue);
  CheckOffset('Flags', 4, @LValue.Flags, @LValue);
  CheckOffset('SubmissionQueueSize', 12, @LValue.SubmissionQueueSize, @LValue);
  CheckOffset('CompletionQueueSize', 16, @LValue.CompletionQueueSize, @LValue);
end;

procedure TWindowsIoRingApiLayoutTests.IORING_CAPABILITIES_Layout;
var
  LValue: IORING_CAPABILITIES;
begin
  AssertEquals('SizeOf', Int64(16), Int64(SizeOf(IORING_CAPABILITIES)));
  CheckOffset('MaxVersion', 0, @LValue.MaxVersion, @LValue);
  CheckOffset('MaxSubmissionQueueSize', 4, @LValue.MaxSubmissionQueueSize, @LValue);
  CheckOffset('MaxCompletionQueueSize', 8, @LValue.MaxCompletionQueueSize, @LValue);
  CheckOffset('FeatureFlags', 12, @LValue.FeatureFlags, @LValue);
end;

procedure TWindowsIoRingApiLayoutTests.IORING_HANDLE_REF_Layout;
var
  LValue: IORING_HANDLE_REF;
begin
  AssertEquals('SizeOf', Int64(2 * POINTER_SIZE), Int64(SizeOf(IORING_HANDLE_REF)));
  CheckOffset('Kind', 0, @LValue.Kind, @LValue);
  CheckOffset('Handle', POINTER_SIZE, @LValue.Handle, @LValue);
  CheckOffset('Index', POINTER_SIZE, @LValue.Index, @LValue);
end;

procedure TWindowsIoRingApiLayoutTests.IORING_REGISTERED_BUFFER_Layout;
var
  LValue: IORING_REGISTERED_BUFFER;
begin
  AssertEquals('SizeOf', Int64(8), Int64(SizeOf(IORING_REGISTERED_BUFFER)));
  CheckOffset('BufferIndex', 0, @LValue.BufferIndex, @LValue);
  CheckOffset('Offset', 4, @LValue.Offset, @LValue);
end;

procedure TWindowsIoRingApiLayoutTests.IORING_BUFFER_REF_Layout;
var
  LValue: IORING_BUFFER_REF;
begin
  AssertEquals('SizeOf', Int64(POINTER_SIZE + 8), Int64(SizeOf(IORING_BUFFER_REF)));
  CheckOffset('Kind', 0, @LValue.Kind, @LValue);
  CheckOffset('Address', POINTER_SIZE, @LValue.Address, @LValue);
  CheckOffset('IndexAndOffset', POINTER_SIZE, @LValue.IndexAndOffset, @LValue);
end;

procedure TWindowsIoRingApiLayoutTests.IORING_BUFFER_INFO_Layout;
var
  LValue: IORING_BUFFER_INFO;
begin
  AssertEquals('SizeOf', Int64(2 * POINTER_SIZE), Int64(SizeOf(IORING_BUFFER_INFO)));
  CheckOffset('Address', 0, @LValue.Address, @LValue);
  CheckOffset('Length', POINTER_SIZE, @LValue.Length, @LValue);
end;

procedure TWindowsIoRingApiLayoutTests.IORING_CQE_Layout;
var
  LValue: IORING_CQE;
begin
  AssertEquals('SizeOf', Int64(3 * POINTER_SIZE), Int64(SizeOf(IORING_CQE)));
  CheckOffset('UserData', 0, @LValue.UserData, @LValue);
  CheckOffset('ResultCode', POINTER_SIZE, @LValue.ResultCode, @LValue);
  CheckOffset('Information', 2 * POINTER_SIZE, @LValue.Information, @LValue);
end;

procedure TWindowsIoRingApiLayoutTests.FILE_SEGMENT_ELEMENT_Layout;
begin
  AssertEquals(Int64(8), Int64(SizeOf(FILE_SEGMENT_ELEMENT)));
end;

procedure TWindowsIoRingApiLayoutTests.IoRingHandleRefFromHandle_SetsRawHandle;
var
  LRef: IORING_HANDLE_REF;
begin
  LRef := IoRingHandleRefFromHandle(THandle($1234));
  AssertEquals('Kind', Int64(IORING_REF_RAW), Int64(LRef.Kind));
  AssertEquals('Handle', Int64($1234), Int64(LRef.Handle));
end;

procedure TWindowsIoRingApiLayoutTests.IoRingHandleRefFromIndex_SetsRegisteredIndex;
var
  LRef: IORING_HANDLE_REF;
begin
  LRef := IoRingHandleRefFromIndex(7);
  AssertEquals('Kind', Int64(IORING_REF_REGISTERED), Int64(LRef.Kind));
  AssertEquals('Index', Int64(7), Int64(LRef.Index));
  // The unused upper part of the union must be zero (Win64)
  AssertEquals('Upper part of the union is zero', Int64(7), Int64(LRef.Handle));
end;

procedure TWindowsIoRingApiLayoutTests.IoRingBufferRefFromPointer_SetsRawAddress;
var
  LRef: IORING_BUFFER_REF;
  LBuffer: array[0..15] of Byte;
begin
  LRef := IoRingBufferRefFromPointer(@LBuffer);
  AssertEquals('Kind', Int64(IORING_REF_RAW), Int64(LRef.Kind));
  AssertTrue('Address', LRef.Address = @LBuffer);
end;

procedure TWindowsIoRingApiLayoutTests.IoRingBufferRefFromIndexAndOffset_SetsRegisteredBuffer;
var
  LRef: IORING_BUFFER_REF;
begin
  LRef := IoRingBufferRefFromIndexAndOffset(3, 4096);
  AssertEquals('Kind', Int64(IORING_REF_REGISTERED), Int64(LRef.Kind));
  AssertEquals('Buffer index', Int64(3), Int64(LRef.IndexAndOffset.BufferIndex));
  AssertEquals('Offset', Int64(4096), Int64(LRef.IndexAndOffset.Offset));
end;

initialization
  RegisterTests(TWindowsIoRingApiLayoutTests);

end.
