import type { NextConfig } from 'next';

const basePath = process.env.NEXT_PUBLIC_BASE_PATH ?? '';
if (basePath !== '' && !/^\/[a-zA-Z0-9_-]+$/.test(basePath)) {
  throw new Error('NEXT_PUBLIC_BASE_PATH must be empty or one path segment, such as /lnpctl');
}
const nextConfig: NextConfig = { output: 'export' };

export default nextConfig;
