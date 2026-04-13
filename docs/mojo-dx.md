# Mojo DX friction

These are not bugs (the service is correct), but each required a workaround that Python would express in one line. They serve as upstream bug reports and feature requests for the Mojo ecosystem.

Items marked **Resolved** were fixed in recent Mojo releases and no longer apply to this codebase.

## Resolved

### ~~`String` byte-range slicing requires `unsafe`~~

**Was:** every substring by byte index used `unsafe_from_utf8=`.

**Now:** Mojo added `from_utf8_lossy=` and byte-range slicing via `[byte=start:end]`:

```mojo
var paste_id = String(from_utf8_lossy=path.removeprefix(_PREFIX).as_bytes())
var val = String(from_utf8_lossy=query[byte=start:end].as_bytes())
```

No `unsafe` keyword required.

### ~~`Request.body` is `List[UInt8]`, not `String`~~

**Was:** every HTTP handler needed a manual byte-copy loop with null termination.

**Now:** `String(from_utf8_lossy=req.body)` works directly:

```mojo
var body = String(from_utf8_lossy=req.body)
cr = read[CreateRequest, default_if_missing=True](body)
```

## Still open

### 1. No way to add ad-hoc fields to `morph.write()` output

`morph.write(paste)` reflects the struct and serialises all fields. The `delete_token` field must not appear in `GET` responses but must appear once in the `POST` response. The handler surgically removes the closing `}` and appends the field manually:

```mojo
var paste_json = _paste_to_json(paste)
var response_json = (
    String(from_utf8_lossy=paste_json[byte=: paste_json.byte_length() - 1].as_bytes())
    + ',"delete_token":"' + delete_token + '"}'
)
```

**Fix needed in `morph`:** `write_with(obj, extra: Dict[String, String])` or a `@skip_serialise` field attribute.

### 2. `fork()`, `sleep()`, `kill()` need raw `external_call`

```mojo
var pid = Int(external_call["fork", Int32]())
_ = external_call["sleep", Int32](Int32(backoff))
_ = external_call["kill", Int32](Int32(pid), Int32(15))
```

**Fix needed in `std.os.process`:** `fork() -> Int`, `sleep(seconds: Int)`, and `kill(pid: Int, sig: Int)`. Basic POSIX wrappers.

### 3. C-FFI `String -> Int` pointer casting and keepalive boilerplate

In `sqlite/ffi.mojo`, every string passed to a C function requires a pointer cast and an explicit `_ = v^` keepalive to prevent premature deallocation:

```mojo
var src = filename.unsafe_ptr()
# ...
_ = v^  # keep v alive past the FFI call
```

**Fix needed in stdlib:** A `String.with_c_ptr { |ptr, len| ... }` scoped helper that guarantees the buffer is alive for the duration of the closure.

## Summary: remaining `unsafe` / workaround usage

| Location | Pattern | Root cause | Fix target |
|----------|---------|-----------|-----------|
| `handlers.mojo` | JSON surgery to inject `delete_token` | `morph` can't add extra fields | `morph` |
| `main.mojo` | `external_call["fork"]` / `sleep` / `kill` | Missing POSIX wrappers | `stdlib` |
| `sqlite/ffi.mojo` | `Int(v.unsafe_ptr())` + `_ = v^` | No scoped C-string helper | `stdlib` |
