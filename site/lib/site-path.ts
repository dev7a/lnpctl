// Raw HTML links and public media do not receive the framework basePath automatically.
export function sitePath(path: string) {
  return `${process.env.NEXT_PUBLIC_BASE_PATH ?? ''}${path}`;
}
