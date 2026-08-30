export function parsePairingURL(pairingURL: string): { relayURL: string; token: string } {
  let url: URL;
  try {
    url = new URL(pairingURL.trim());
  } catch {
    throw new Error("Scan or paste a valid MacScope pairing URL.");
  }
  if (url.protocol !== "https:" && !(url.protocol === "http:" && ["localhost", "127.0.0.1"].includes(url.hostname))) {
    throw new Error("Pairing requires HTTPS, except for local relay development.");
  }
  const params = new URLSearchParams(url.hash.replace(/^#/u, ""));
  const token = params.get("token");
  if (!token) throw new Error("The pairing URL does not contain its one-time token.");
  return { relayURL: url.origin, token };
}

export function webSocketURL(relayURL: string, ticket: string): string {
  const url = new URL("/v1/socket", relayURL);
  url.protocol = url.protocol === "http:" ? "ws:" : "wss:";
  url.searchParams.set("ticket", ticket);
  return url.toString();
}
