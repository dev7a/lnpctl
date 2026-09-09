import type { Metadata } from 'next';
import './globals.css';
export const metadata: Metadata = {
  title: 'lnpctl guide | Experimental macOS Local Network cleanup',
  description: 'Build, prepare, apply from Recovery, and restore a selective Local Network cleanup. Very experimental software. Run at your own risk and peril.',
};
export default function RootLayout({ children }: { children: React.ReactNode }) {
  return <html lang="en"><body>{children}</body></html>;
}
