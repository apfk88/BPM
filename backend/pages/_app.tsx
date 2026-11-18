import type { AppProps } from 'next/app'
import { Analytics } from '@vercel/analytics/react'
import { useRouter } from 'next/router'

export default function App({ Component, pageProps }: AppProps) {
  const pathname = useRouter().pathname;
  const isPrivateLink = pathname.startsWith('/join/') || pathname.startsWith('/w/');
  return (
    <>
      <Component {...pageProps} />
      {!isPrivateLink && <Analytics />}
    </>
  )
}

