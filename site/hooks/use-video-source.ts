'use client';
import { useEffect, useState } from 'react';

// Sites serves these small MP4s as complete responses even to Range requests.
// A local object URL lets the native player seek through the downloaded file.
export function useVideoSource(url: string) {
  const [source, setSource] = useState<string>();
  useEffect(() => {
    const controller = new AbortController();
    let objectUrl: string | undefined;
    setSource(undefined);
    fetch(url, { signal: controller.signal })
      .then(response => {
        if (!response.ok) throw new Error(`Video request failed: ${response.status}`);
        return response.blob();
      })
      .then(blob => {
        if (controller.signal.aborted) return;
        objectUrl = URL.createObjectURL(blob);
        setSource(objectUrl);
      })
      .catch(() => {
        if (!controller.signal.aborted) setSource(url);
      });
    return () => {
      controller.abort();
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
  }, [url]);
  return source;
}
