/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  async headers() {
    return ['/w/:path*', '/join/:path*', '/api/workout-pages/:path*', '/api/share/:path*'].map(source => ({
      source,
      headers: [
        { key: 'X-Robots-Tag', value: 'noindex, nofollow, noarchive, nosnippet' },
        { key: 'Referrer-Policy', value: 'no-referrer' },
        { key: 'X-Content-Type-Options', value: 'nosniff' },
        { key: 'X-Frame-Options', value: 'DENY' },
      ],
    }));
  },
  async rewrites() {
    return [
      { source: '/', destination: '/index.html' },
      { source: '/changelog', destination: '/changelog.html' },
    ];
  },
};

module.exports = nextConfig;
