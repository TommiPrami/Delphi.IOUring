# Coding style

How the code of Delphi.IOUring is written. It applies to all code in this
repository – `Source/Units`, `Source/UnitTests`, `Source/Demos` and
`Source/Benchmarks` – but not to third-party code (`Source/3rdParty`) or to
files that tools write (the Lazarus package's `DelphiIOUring.pas`).

What both compilers must support, and the rules for `inline`, are in
[Design.md](Design.md) §12.2 and §12.3.

## Files

- Pascal files (`.pas`, `.inc`, `.dpr`, `.lpr`, `.dproj`): UTF-8 with BOM,
  CRLF line ends. After editing, run from the repository root:
  `pwsh -NoProfile -Command "& .\Normalize-SourceEncoding.ps1 -Root Source -Extensions .pas,.inc,.dpr,.dproj,.lpr"`
- Markdown files: UTF-8 with BOM, LF line ends.
- No spaces at the end of a line.

## Names

- Parameters start with `A`, local variables with `L`, fields with `F`,
  global variables with `G`.
- Types start with `T`, pointer types with `P`, exceptions with `E`.
- Constants are `UPPER_CASE`.

## Layout

- Indent with 2 spaces, no tabs. `begin` and `end` on lines of their own.
- **Right margin: 120 characters.** It is a soft limit: break code and
  comments at a sensible place – after a comma, between parameters, before
  `and`/`or` – and a few characters over is fine when the line reads better
  that way. A continued line is indented 2 more than its start. A statement
  that fits on one line is written on one line.
- **In the interface section, function and procedure declarations are
  indented by 2**, with their comments, so the `type`, `const` and
  `implementation` sections stand out.
- The OS API translation units (`Delphi.IOUring.Backend.Windows.API`,
  `Delphi.IOUring.Backend.Posix.API`) keep the layout of the C headers they
  translate.

```pascal
function IORingReadAt(var ARing: TIORing; const AFile: TIORingFileRef; var ABuffer; const ACount: Cardinal;
  const AOffset: UInt64): Cardinal;
```

## Empty lines

- **Every block statement stands apart:** an `if`, `for`, `while`,
  `repeat`, `case`, `try` or `with` gets an empty line before it and after
  it.
- **No empty line where the indentation changes:** none right after
  `begin`, `try`, `repeat` or `then`, and none before `end`, `else`,
  `until`, `except` or `finally`.
- **Exception: the `try` that protects what the line above created**
  follows it directly – the block belongs to that line:

```pascal
  LStream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    LStream.ReadBuffer(LBuffer[0], Length(LBuffer));
  finally
    LStream.Free;
  end;
```

- Also an empty line before `Exit`, `Continue` or `Break` that follows other
  statements, and before the `Result :=` that ends a routine.
- In type declarations: an empty line between a pointer type and its record,
  and between an enumeration and its set type.

```pascal
  LSlot := @FSlots[FHead];

  if LSlot.State = rssFree then
    IssueReads;

  if LSlot.State = rssInFlight then
  begin
    ProcessCompletions;

    if LSlot.State = rssInFlight then
    begin
      if not AWait then
        Exit(False);

      Stall;
    end;
  end;

  Result := FHeadOffset < LSlot.BytesRead;
```

```pascal
  PIORingReaderSlot = ^TIORingReaderSlot;

  TIORingReaderSlot = record
    State: TIORingReaderSlotState;
    Data: PByte;
  end;
```

## Comments

- One line: `//`. Also for a short comment after code on the same line.
- **Several lines: a `{ }` block, never a run of `//` lines.** For two
  lines the braces can share the lines with the text; for more, the braces
  stand on lines of their own – whichever is cleaner in that spot.
- If the text has braces itself (compiler directives, for example), use
  `(* *)` instead.
- A comment is indented like the code it belongs to. The unit's header
  comment starts at column 0.

```pascal
unit Delphi.IOUring.SequentialReader;

{
  Reads a file front to back with read-ahead (Docs/Design.md §7).

  BufferCount buffers of BufferSize bytes form a circular queue. Reads for the next buffers are in flight while the
  caller works on the current one, so in the best case Read only copies data that is already there.
}
```

```pascal
      { Nothing in flight and nothing could be started: should not happen (the ring has room for every buffer and
        every piece) }
      RaiseIORingError('Reads straight into the caller''s memory could not be started');
```

## Statements

- **`inherited` always with the method's name** – `inherited Create;`,
  `inherited Destroy;`, never a bare `inherited;` – and set apart with an
  empty line, so it is not missed.

```pascal
destructor TSequentialReadOnlyFileStream.Destroy;
begin
  FReader.Close;

  inherited Destroy;
end;
```

- **`case`:** a short branch on one line; `else` is indented like the
  branches.

```pascal
  case Origin of
    soBeginning: LTarget := Offset;
    soCurrent: LTarget := FReader.Position + Offset;
    else
      LTarget := FReader.Size + Offset;
  end;
```

- **`uses`:** the units on one line, wrapped at the margin; `{$IFDEF FPC}`
  only where the two compilers need different names.

```pascal
uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  Delphi.IOUring, Delphi.IOUring.Engine;
```

## Speed

Delphi optimizes little, so some code must be made fast by hand.

### Raising: small raise procedures and the raise helpers

No exception text in the routine that does the work. Measured with Delphi
(Win32, `{$O+}`, 2026-10-24) on a routine that checks a value and doubles it:

| How it raises | Routine size | Hidden `try`/`finally` |
| --- | ---: | --- |
| `raise EIORingError.Create('…text…')` | 132 bytes | no |
| a raise helper with the text: `RaiseIORingError('…text…')` | 120 bytes | no |
| a raise helper with `'…' + IntToStr(AValue)` | 140 bytes | **yes** |
| `raise EIORingError.Create(Format(…))` | 156 bytes | **yes** |
| **a nested raise procedure without the text in the routine** | **20 bytes** | no |

- Building the text in the routine (`Format`, `+`, `IntToStr`) makes the
  compiler add a hidden `try`/`finally` for the temporary strings, paid on
  every call, also when nothing is raised.
- A constant text adds no `try`/`finally`, but Delphi stores it right after
  the routine's code: the routine is about 6 times bigger, and the text sits
  in the same cache lines as the code that runs.

So the text and the raising go into a **small raise procedure**, named
`Raise…` (for example `RaiseBufferSizeZero`); the routine only calls it,
passing the values the message needs as parameters (not reading them from
the routine – that would keep them out of registers there):

- **used once** in a unit or class: a nested procedure of the routine
  (between its header and its `var`);
- **used in several places:** a procedure of the unit's implementation
  section, or a private method.

The small procedure raises through one of the raise helpers of
`Delphi.IOUring.Backend.Custom`:

| Helper | Raises |
| --- | --- |
| `RaiseIORingError(AMessage)` | `EIORingError.Create` |
| `RaiseIORingErrorFmt(AFormat, AArgs)` | `EIORingError.CreateFmt` |
| `RaiseIORingErrorNative(ANativeCode, AOperation)` | `EIORingError.CreateNative` |
| `RaiseIORingErrorNativeFmt(ANativeCode, AFormat, AArgs)` | `EIORingError.CreateNative`, the operation formatted |
| `RaiseError(AClass, AMessage)` | any exception class, `Create` |
| `RaiseErrorFmt(AClass, AFormat, AArgs)` | any exception class, `CreateFmt` |

```pascal
procedure TIORingSequentialReader.Open(const AHandle: THandle; const AOwnsHandle: Boolean;
  const AOptions: TIORingSequentialReaderOptions; const ABufferSize, ABufferCount: Cardinal);

  procedure RaiseBufferCountOutOfRange(const ACount: Cardinal); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorFmt('Buffer count %d is not between 1 and %d', [ACount, IORING_READER_MAX_BUFFER_COUNT]);
  end;

var
  LTotalSize: UInt64;
begin
  if (ABufferCount = 0) or (ABufferCount > IORING_READER_MAX_BUFFER_COUNT) then
    RaiseBufferCountOutOfRange(ABufferCount);
```

- In the small procedure, **pass a constant text, or a format and its
  arguments** to the helper – not `Format(…)` or `'…' + S`.
- The small procedure gets `{$IFNDEF FPC} noreturn; {$ENDIF}`: Delphi then
  knows that the routine does not go on after the call (no "might be
  undefined" warnings). Its parameters have their own names, not the names
  of the routine's parameters.
- The helpers raise **at their caller's address** (Delphi `ReturnAddress`,
  Free Pascal `get_caller_addr`): the exception points into the small raise
  procedure, and the stack trace shows the routine that called it. With
  Delphi the helpers are `noreturn`;
  Free Pascal does not get it, because FPC's trunk refuses `noreturn` on a
  routine that raises (measured 2026-10-24).
- `raise;` (raise the current exception again) stays as it is.

### Parameters

- **`const` or `var` whenever possible.** Avoid `out`: Delphi handles it
  less well. Exceptions: the public API (`TryPopCompletion`,
  `TryAcquireChunk`, `TIORingEngine.Wait` …) may keep `out` – it is not
  called in the tightest loops, and `out` tells the caller that the value is
  only written; translations of OS functions keep the OS's meaning; Delphi's
  managed-record `Initialize` operator must be `out`.
- `TAtomic`'s value parameters stay as they are: some of its routines are
  assembler, and `const` could change how Free Pascal passes an `Int64` on
  Win32.
- **The same group of parameters passed to many places:** make it a record
  and pass that by reference (`const [ref]` – in shared code
  `{$IFDEF FPC}constref{$ELSE}const [ref]{$ENDIF}` – `var`, or a pointer),
  if that lets everything go in registers. Only where there are many such
  places.

### inline

See [Design.md](Design.md) §12.3: the body before the first call, the
implementing unit in the caller's `uses`, and inlining off in Debug builds.
