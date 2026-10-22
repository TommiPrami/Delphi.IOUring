unit Tests.FPC.Backend.Windows.API.Layout;

{
  Free Pascal version of Tests.Backend.Windows.API.Layout: record sizes and
  field offsets must equal the C (MSVC) layout, with FPC's own record rules.
}

{$I Delphi.IOUring.inc}

interface

uses
  Tests.FPC.Support;

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
    procedure Helpers_SetKindAndValue;
  end;

implementation

uses
  Windows,
  testregistry,
  Delphi.IOUring.Backend.Windows.API;

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

procedure TWindowsIoRingApiLayoutTests.Helpers_SetKindAndValue;
var
  LHandleRef: IORING_HANDLE_REF;
  LBufferRef: IORING_BUFFER_REF;
  LBuffer: array[0..15] of Byte;
begin
  LHandleRef := IoRingHandleRefFromHandle(THandle($1234));
  AssertEquals('Raw handle kind', Int64(IORING_REF_RAW), Int64(LHandleRef.Kind));
  AssertEquals('Raw handle', Int64($1234), Int64(LHandleRef.Handle));

  LHandleRef := IoRingHandleRefFromIndex(7);
  AssertEquals('Index kind', Int64(IORING_REF_REGISTERED), Int64(LHandleRef.Kind));
  AssertEquals('Index', Int64(7), Int64(LHandleRef.Index));
  AssertEquals('Upper part of the union is zero', Int64(7), Int64(LHandleRef.Handle));

  LBufferRef := IoRingBufferRefFromPointer(@LBuffer);
  AssertEquals('Pointer kind', Int64(IORING_REF_RAW), Int64(LBufferRef.Kind));
  AssertTrue('Pointer', LBufferRef.Address = @LBuffer);

  LBufferRef := IoRingBufferRefFromIndexAndOffset(3, 4096);
  AssertEquals('Registered kind', Int64(IORING_REF_REGISTERED), Int64(LBufferRef.Kind));
  AssertEquals('Buffer index', Int64(3), Int64(LBufferRef.IndexAndOffset.BufferIndex));
  AssertEquals('Offset', Int64(4096), Int64(LBufferRef.IndexAndOffset.Offset));
end;

initialization
  RegisterTest(TWindowsIoRingApiLayoutTests);

end.
