const downloads = [
  { os: 'macOS', file: 'Weeber-mac.dmg', requirement: 'macOS 12 or later' },
  { os: 'Windows', file: 'Weeber-windows.exe', requirement: 'Windows 10 or later' },
  { os: 'Linux', file: 'Weeber-linux.AppImage', requirement: 'Most modern distros' },
];

export default function DownloadPage() {
  return (
    <div className="mx-auto max-w-3xl px-6 py-16">
      <h1 className="text-4xl font-semibold text-center">Download Weeber</h1>
      <p className="mt-3 text-center text-slate-600">
        Install on the device you want to use as your storage. Mobile clients are on the
        App Store and Play Store.
      </p>

      <div className="mt-12 space-y-4">
        {downloads.map((d) => (
          <div
            key={d.os}
            className="flex items-center justify-between rounded-lg border border-slate-200 p-5"
          >
            <div>
              <h3 className="font-semibold">{d.os}</h3>
              <p className="text-sm text-slate-500">{d.requirement}</p>
            </div>
            <a
              href={`/installers/${d.file}`}
              className="rounded-md bg-slate-900 px-4 py-2 text-sm text-white hover:bg-slate-700"
            >
              Download
            </a>
          </div>
        ))}
      </div>

      <div className="mt-12 grid gap-4 md:grid-cols-2">
        <a
          href="https://apps.apple.com/"
          className="rounded-lg border border-slate-200 p-5 hover:bg-slate-50"
        >
          <h3 className="font-semibold">iPhone &amp; iPad</h3>
          <p className="text-sm text-slate-500">Get it on the App Store</p>
        </a>
        <a
          href="https://play.google.com/"
          className="rounded-lg border border-slate-200 p-5 hover:bg-slate-50"
        >
          <h3 className="font-semibold">Android</h3>
          <p className="text-sm text-slate-500">Get it on Google Play</p>
        </a>
      </div>
    </div>
  );
}
