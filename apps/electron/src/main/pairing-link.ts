/**
 * Builds the pairing link the QR code carries:
 * `<pwaBaseURL>/#s=<secret>&server=<ntfy>&local=<lan-url>`.
 *
 * `localURL` rides along in the same code the PWA already reads: the PWA ignores unknown
 * fragment parameters, so one code pairs both the PWA and the mobile app.
 */
export function pairingLink(secretBase64: string, pwaBaseURL: string, ntfyServer: string, localURL: string | null): string {
  const link = `${pwaBaseURL}/#s=${secretBase64}&server=${urlQueryEncode(ntfyServer)}`;
  return localURL ? `${link}&local=${urlQueryEncode(localURL)}` : link;
}

/**
 * Percent-encodes exactly like the native app's `addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)`,
 * which leaves `:` and `/` literal.
 *
 * This is not cosmetic. The iOS client parses the fragment by assigning it to
 * `URLComponents.query` (`MetriaMobileKit/PairingConfiguration.swift`), and that setter
 * treats the string as already decoded — so anything escaped here reaches the phone still
 * escaped, and it would try to reach a relay literally named `https%3A%2F%2Fntfy.sh`.
 */
function urlQueryEncode(value: string): string {
  // Swift's .urlQueryAllowed additionally permits $ & + , / : ; = ? @ over what
  // encodeURIComponent leaves alone.
  return encodeURIComponent(value).replace(/%(24|26|2B|2C|2F|3A|3B|3D|3F|40)/g, (_, code: string) => String.fromCharCode(parseInt(code, 16)));
}
