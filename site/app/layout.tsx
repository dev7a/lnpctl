import type { Metadata } from 'next';
import './globals.css';
export const metadata: Metadata = {
  title: 'lnpctl guide | Experimental macOS Local Network cleanup',
  description: 'Build, prepare, apply from Recovery, and restore a selective Local Network cleanup. Very experimental software. Run at your own risk and peril.',
  openGraph: {
    type: 'website',
    siteName: 'lnpctl',
    title: 'lnpctl — macOS Local Network permission cleanup',
    description: 'Experimental, open-source cleanup tool. Prepare changes, apply from macOS Recovery, and keep SIP enabled.',
    images: [{
      url: 'https://dev7a.github.io/lnpctl/media/social-preview.png',
      width: 1280,
      height: 640,
      alt: 'lnpctl — macOS Local Network permission cleanup. Experimental, open source, MIT.',
    }],
  },
  twitter: {
    card: 'summary_large_image',
    title: 'lnpctl — macOS Local Network permission cleanup',
    description: 'Experimental, open-source cleanup tool. Prepare changes, apply from macOS Recovery, and keep SIP enabled.',
    images: ['https://dev7a.github.io/lnpctl/media/social-preview.png'],
  },
};
export default function RootLayout({ children }: { children: React.ReactNode }) {
  return <html lang="en"><body>{children}</body></html>;
}
