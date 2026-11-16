// Footage upload for the editing dashboard: the Drive's chunked sessions (init and
// complete on the team project, chunks through /api/upload/chunk), 4 chunks in flight
// per file, and resume: the session id is kept per file, so adding the same file again
// after a closed tab or a dropped connection only sends the missing chunks.

import { ApiError, uploadComplete, uploadInit, uploadStatus } from "./editing-api.js?v=20261116-teamproj";

const MIB = 1024 * 1024;
export const STREAMS = 4; // parallel chunk PUTs per file
const MAX_CHUNK = 32 * MIB; // the server's limit
const RESUME_PREFIX = "ifd-edit-upload|";
const RETRIES = 4;

const BASE_CHUNK = 8 * MIB; // a dropped upload loses at most STREAMS of these
const MAX_CHUNKS = 256;

/** Chunk size: 8 MiB (smaller files split into STREAMS pieces, 1 MiB at least); very big
 *  files grow it so there are at most ~256 chunks, up to the server's 32 MiB. */
export function chunkSizeFor(size) {
  const bytes = Math.max(1, size);
  const small = Math.ceil(bytes / STREAMS / MIB) * MIB;
  const big = Math.ceil(bytes / MAX_CHUNKS / MIB) * MIB;
  return Math.min(MAX_CHUNK, Math.max(MIB, Math.min(BASE_CHUNK, small), big));
}

function resumeKey(projectId, file) {
  return `${RESUME_PREFIX}${projectId}|${file.name}|${file.size}|${file.lastModified || 0}`;
}

function remember(key, value) {
  try {
    if (value) localStorage.setItem(key, value);
    else localStorage.removeItem(key);
  } catch {
    /* private mode: no resume, upload still works */
  }
}

function recall(key) {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

function putChunk(uploadId, index, blob, onLoaded, xhrs) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhrs.add(xhr);
    xhr.open("PUT", `/api/upload/chunk?upload_id=${encodeURIComponent(uploadId)}&index=${index}`);
    xhr.withCredentials = true;
    xhr.setRequestHeader("Content-Type", "application/octet-stream");
    xhr.upload.onprogress = (event) => onLoaded(event.loaded);
    xhr.onloadend = () => xhrs.delete(xhr);
    xhr.onload = () =>
      xhr.status >= 200 && xhr.status < 300
        ? resolve()
        : reject(new ApiError(`Chunk ${index} failed (${xhr.status})`, xhr.status));
    xhr.onerror = () => reject(new ApiError("Connection dropped", 0));
    xhr.onabort = () => reject(new ApiError("Cancelled", 0, "cancelled"));
    xhr.send(blob);
  });
}

async function openSession(projectId, file) {
  const key = resumeKey(projectId, file);
  const existing = recall(key);
  if (existing) {
    try {
      const st = await uploadStatus(existing);
      if (st && st.size === file.size && st.name === file.name) return { ...st, upload_id: existing };
    } catch {
      /* expired: start over */
    }
    remember(key, null);
  }
  const session = await uploadInit(projectId, { name: file.name, size: file.size, chunk_size: chunkSizeFor(file.size) });
  remember(key, session.upload_id);
  return { ...session, received: session.received || [] };
}

/**
 * Upload one file into the project's media folder.
 * onProgress({ loaded, total, resumed }) runs as bytes go out.
 * @returns {{ promise: Promise<object>, cancel: () => void }}
 */
export function uploadFootage(projectId, file, onProgress) {
  const xhrs = new Set();
  let cancelled = false;

  const promise = (async () => {
    const session = await openSession(projectId, file);
    const size = session.chunk_size;
    const total = session.total_chunks;
    const done = new Set(session.received);
    const loaded = Array.from({ length: total }, (_, i) =>
      done.has(i) ? Math.min(size, file.size - i * size) : 0,
    );
    const resumed = done.size > 0;
    const report = () => onProgress?.({ loaded: loaded.reduce((a, b) => a + b, 0), total: file.size, resumed });
    report();
    const queue = Array.from({ length: total }, (_, i) => i).filter((i) => !done.has(i));

    const worker = async () => {
      while (!cancelled && queue.length) {
        const index = queue.shift();
        const blob = file.slice(index * size, Math.min(file.size, (index + 1) * size));
        for (let attempt = 1; ; attempt += 1) {
          try {
            await putChunk(session.upload_id, index, blob, (n) => {
              loaded[index] = n;
              report();
            }, xhrs);
            loaded[index] = blob.size;
            report();
            break;
          } catch (error) {
            if (cancelled || attempt >= RETRIES) throw error;
            loaded[index] = 0;
            await new Promise((r) => setTimeout(r, 500 * attempt));
          }
        }
      }
    };
    await Promise.all(Array.from({ length: Math.min(STREAMS, Math.max(1, queue.length)) }, worker));
    if (cancelled) throw new ApiError("Cancelled", 0, "cancelled");
    const result = await uploadComplete(projectId, session.upload_id);
    remember(resumeKey(projectId, file), null);
    return result;
  })();

  return {
    promise,
    cancel: () => {
      cancelled = true;
      for (const xhr of xhrs) xhr.abort();
    },
  };
}
