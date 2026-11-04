import type { AppProps } from 'next/app'
import { Analytics } from '@vercel/analytics/react'
import { useRouter } from 'next/router'

export default function App({ Component, pageProps }: AppProps) {
  const isJoinLink = useRouter().pathname.startsWith('/join/');
  return (
    <>
      <Component {...pageProps} />
      {!isJoinLink && <Analytics />}
    </>
  )
}

