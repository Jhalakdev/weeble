'use client';

import { useEffect, useRef, useState } from 'react';
import { X } from 'lucide-react';
import QrScanner from 'qr-scanner';

/// Full-screen QR scanner modal. Camera stream via getUserMedia,
/// decoded locally via qr-scanner (WebWorker, ~15 KB). Fires
/// onScan exactly once when a QR payload is decoded, then stops
/// the camera + closes.
export function QRScanner({
  onScan, onClose,
}: {
  onScan: (payload: string) => void;
  onClose: () => void;
}) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    const vid = videoRef.current;
    if (!vid) return;
    let fired = false;
    const scanner = new QrScanner(
      vid,
      (result) => {
        if (fired) return;
        fired = true;
        try { scanner.stop(); } catch {}
        onScan(result.data);
      },
      {
        preferredCamera: 'environment', // rear camera on phones
        highlightScanRegion: true,
        highlightCodeOutline: true,
      },
    );
    scanner.start().catch((e) => setErr(String(e?.message ?? e)));
    return () => {
      try { scanner.stop(); } catch {}
      scanner.destroy();
    };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <div className="fixed inset-0 z-50 bg-black flex flex-col" role="dialog" aria-modal="true">
      <div className="flex items-center justify-between px-4 py-3 text-white">
        <div>
          <div className="text-[14px] font-semibold">Scan QR</div>
          <div className="text-[11px] opacity-70">Point at the QR shown by your Weeber app</div>
        </div>
        <button onClick={onClose} className="p-2 rounded-full hover:bg-white/10" aria-label="Close"><X size={20} /></button>
      </div>
      <div className="flex-1 relative">
        {err ? (
          <div className="absolute inset-0 flex items-center justify-center p-6 text-center">
            <div className="text-white">
              <div className="text-[14px] font-semibold mb-2">Camera unavailable</div>
              <div className="text-[12px] opacity-80 max-w-xs mx-auto leading-relaxed">{err}</div>
              <div className="text-[11px] opacity-60 mt-4">Allow camera access in your browser and retry, or sign in with email instead.</div>
            </div>
          </div>
        ) : (
          <video
            ref={videoRef}
            className="w-full h-full object-cover"
            playsInline
            muted
          />
        )}
      </div>
    </div>
  );
}
