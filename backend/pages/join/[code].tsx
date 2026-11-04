import Head from 'next/head';
import type { GetServerSideProps } from 'next';

export default function JoinSession({ code }: { code: string }) {
  return (
    <>
      <Head>
        <title>Join a BPM session</title>
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex, nofollow" />
        <meta name="referrer" content="no-referrer" />
        <meta name="description" content="Train together with live heart rate and workout controls." />
      </Head>
      <main>
        <h1>Train together.</h1>
        <p>View your friend’s heart rate and control the workout in BPM.</p>
        <a className="open" href={`bpm://join?code=${code}`}>Open in BPM</a>
        <p className="code">Or enter code <strong>{code.slice(0, 3)} {code.slice(3)}</strong> in Device.</p>
        <a className="store" href="https://apps.apple.com/app/id6754830191">Get BPM for iPhone</a>
      </main>
      <style jsx global>{`
        html, body { margin: 0; background: #080808; color: #f5f5f5; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
        main { max-width: 420px; padding: 80px 24px; margin: auto; }
        h1 { font-size: 38px; letter-spacing: -1px; margin: 0 0 16px; }
        p { color: #aaa; line-height: 1.5; }
        a { color: inherit; }
        .open { display: block; margin: 32px 0 20px; padding: 17px; border-radius: 14px; background: #16d85c; color: #050505; text-align: center; text-decoration: none; font-weight: 650; }
        .code { font-size: 15px; }
        strong { color: #f5f5f5; font-variant-numeric: tabular-nums; white-space: nowrap; }
        .store { display: inline-block; margin-top: 20px; font-size: 15px; }
      `}</style>
    </>
  );
}

export const getServerSideProps: GetServerSideProps = async ({ params, res }) => {
  const code = params?.code;
  if (typeof code !== 'string' || !/^\d{6}$/.test(code)) return { notFound: true };
  res.setHeader('Cache-Control', 'private, no-store');
  res.setHeader('Referrer-Policy', 'no-referrer');
  return { props: { code } };
};
