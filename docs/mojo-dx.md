# Mojo DX friction

These are not bugs (the service is correct), but each required a workaround that Python would express in one line. They serve as upstream bug reports and feature requests for the Mojo ecosystem.

## 1. `String` byte-range slicing requires `unsafe`

Every substring by byte index uses the `unsafe_from_utf8=` escape hatch:

```mojo
var paste_id = String(unsafe_from_utf8=path.as_bytes()[_PREFIX.byte_length():])
val_str = String(unsafe_from_utf8=query.as_bytes()[start:end])
```

**Fix needed in stdlib:** `String.__getitem__(Slice) -> String` that trusts the caller's byte slice.

## 2. `Request.body` is `List[UInt8]`, not `String`

Every HTTP handler must manually copy the byte list and null-terminate before JSON parsing:

```mojo
var raw = List[UInt8](capacity=len(req.body) + 1)
for b in req.body:
    raw.append(b)
raw.append(0)
var body = String(unsafe_from_utf8=raw)
```

**Fix needed in `flare`:** `Request.text() -> String` (UTF-8 decode of the body).

## 3. No way to add ad-hoc fields to `morph.write()` output

`morph.write(paste)` reflects the struct and serialises all fields. The `delete_token` field must not appear in `GET` responses but must appear once in the `POST` response. The handler surgically removes the closing `}` and appends the field manually.

**Fix needed in `morph`:** `write_with(obj, extra: Dict[String, String])` or a `@skip_serialise` field attribute.

## 4. `fork()`, `sleep()`, `kill()` need raw `external_call`

```mojo
var pid = Int(external_call["fork", Int32]())
_ = external_call["sleep", Int32](Int32(backoff))
_ = external_call["kill", Int32](Int32(pid), Int32(15))
```

**Fix needed in `std.os.process`:** `fork() -> Int`, `sleep(seconds: Int)`, and `kill(pid: Int, sig: Int)`.

## 5. C-FFI `String -> Int` pointer casting and keepalive boilerplate

In `sqlite/ffi.mojo`, every string passed to a C function requires a manual copy, pointer cast, and an explicit `_ = v^` keepalive to prevent premature deallocation.

**Fix needed in stdlib:** A `String.with_c_ptr { |ptr, len| ... }` scoped helper that guarantees the buffer is alive for the duration of the closure.

## Summary: `unsafe` usage

| Location | `unsafe` pattern | Root cause | Fix target |
|----------|-----------------|-----------|-----------|
| `router.mojo` | `String(unsafe_from_utf8=path.as_bytes()[n:])` | No `String` slice | `stdlib` |
| `handlers.mojo` | byte-copy loop + `unsafe_from_utf8=` for body | `Request.body` is `List[UInt8]` | `flare` |
| `handlers.mojo` | JSON surgery to inject `delete_token` | `morph` can't add extra fields | `morph` |
| `handlers.mojo` | `String(unsafe_from_utf8=query.as_bytes()[s:e])` | No `String` slice | `stdlib` |
| `morph/value.mojo` | `String(unsafe_from_utf8=data[i:i+n])` (x6) | No `String` slice | `stdlib` |
| `sqlite/ffi.mojo` | `Int(v.unsafe_ptr())` + `_ = v^` (x4) | No scoped C-string helper | `stdlib` |
| `main.mojo` | `external_call["fork"]` / `sleep` / `kill` | Missing POSIX wrappers | `stdlib` |
