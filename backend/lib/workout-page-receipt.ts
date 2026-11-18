import { createPublicKey, webcrypto, X509Certificate } from 'node:crypto';
import * as asn1js from 'asn1js';
import * as pkijs from 'pkijs';

// Apple public root downloaded from https://www.apple.com/certificateauthority/AppleRootCA-G3.cer.
// Pin this trust anchor; a root supplied inside an untrusted receipt is never sufficient.
const APPLE_ROOT_G3 = `-----BEGIN CERTIFICATE-----
MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==
-----END CERTIFICATE-----`;

function parseASN(bytes: Buffer): asn1js.AsnType {
  const result = asn1js.fromBER(bytes);
  if (result.offset !== bytes.length || result.result.error) throw new Error('Invalid receipt ASN.1');
  return result.result;
}

export async function verifyAppleReceipt(receipt: Buffer, appID: string, publicKey: string, now = Date.now()): Promise<void> {
  if (receipt.length > 32768) throw new Error('Receipt too large');
  const content = new pkijs.ContentInfo({ schema: parseASN(receipt) });
  if (content.contentType !== '1.2.840.113549.1.7.2') throw new Error('Receipt is not SignedData');
  const signed = new pkijs.SignedData({ schema: content.content });
  if (signed.signerInfos.length !== 1 || !signed.certificates?.length || signed.certificates.length > 6
      || !['2.16.840.1.101.3.4.2.1', '2.16.840.1.101.3.4.2.2', '2.16.840.1.101.3.4.2.3']
        .includes(signed.signerInfos[0].digestAlgorithm.algorithmId)) throw new Error('Invalid receipt signer');
  const root = new pkijs.Certificate({ schema: parseASN(new X509Certificate(APPLE_ROOT_G3).raw) });
  const engine = new pkijs.CryptoEngine({ name: 'node', crypto: webcrypto as unknown as Crypto });
  const verification = await signed.verify({ signer: 0, checkChain: true, trustedCerts: [root], checkDate: new Date(now),
    extendedMode: true }, engine);
  if (!verification.signatureVerified || !verification.signerCertificateVerified) throw new Error('Receipt signature is invalid');
  const payload = signed.encapContentInfo.eContent;
  if (!payload) throw new Error('Receipt payload missing');
  const set = parseASN(Buffer.from(payload.getValue()));
  if (!(set instanceof asn1js.Set)) throw new Error('Receipt payload is not a set');
  const fields = new Map<number, Buffer>();
  for (const entry of set.valueBlock.value) {
    if (!(entry instanceof asn1js.Sequence) || entry.valueBlock.value.length !== 3) throw new Error('Invalid receipt field');
    const [type, version, value] = entry.valueBlock.value;
    if (!(type instanceof asn1js.Integer) || !(version instanceof asn1js.Integer) || !(value instanceof asn1js.OctetString)
        || fields.has(type.valueBlock.valueDec)) throw new Error('Invalid receipt field');
    fields.set(type.valueBlock.valueDec, Buffer.from(value.getValue()));
  }
  if (fields.get(2)?.toString('utf8') !== appID || fields.get(6)?.toString('utf8') !== 'ATTEST') throw new Error('Receipt app mismatch');
  const created = Date.parse(fields.get(12)?.toString('utf8') || '');
  if (!Number.isFinite(created) || created < now - 300000 || created > now + 60000) throw new Error('Receipt is not fresh');
  const certificateBytes = fields.get(3);
  if (!certificateBytes) throw new Error('Receipt key missing');
  const receiptKey = new X509Certificate(certificateBytes).publicKey.export({ type: 'spki', format: 'der' });
  const expected = createPublicKey(publicKey).export({ type: 'spki', format: 'der' });
  if (!receiptKey.equals(expected)) throw new Error('Receipt key mismatch');
}
