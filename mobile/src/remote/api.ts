import { fetch } from "expo/fetch";
import type {
  EnvironmentSummary,
  NotificationPreferences,
  PairingRedemption,
  RemoteRole,
  StoredEnvironment,
} from "./types";
import { parsePairingURL } from "./urls";

export class RemoteApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly code: string,
  ) {
    super(message);
    this.name = "RemoteApiError";
  }
}

type TokenUpdate = Pick<StoredEnvironment, "accessToken" | "accessExpiresAt" | "refreshToken" | "refreshExpiresAt">;

export class RemoteApi {
  private refreshPromise: Promise<TokenUpdate> | null = null;

  constructor(
    private environment: StoredEnvironment,
    private readonly onTokens: (tokens: TokenUpdate) => Promise<void>,
  ) {}

  static async redeemPairing(input: {
    pairingURL: string;
    displayName: string;
    deviceName: string;
    platform: "ios" | "android" | "unknown";
    pushToken?: string;
  }): Promise<StoredEnvironment> {
    const parsed = parsePairingURL(input.pairingURL);
    const redemption = await rawRequest<PairingRedemption>(`${parsed.relayURL}/v1/pairings/redeem`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        pairingToken: parsed.token,
        displayName: input.displayName,
        deviceName: input.deviceName,
        platform: input.platform,
        pushToken: input.pushToken,
      }),
    });
    return {
      ...redemption,
      relayURL: parsed.relayURL,
      displayName: `Mac ${redemption.environmentID.slice(0, 6)}`,
    };
  }

  replaceEnvironment(environment: StoredEnvironment): void {
    this.environment = environment;
  }

  async webSocketTicket(): Promise<{ ticket: string; expiresAt: string }> {
    return this.authRequest("/v1/ws-ticket", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ environmentID: this.environment.environmentID, clientKind: "mobile" }),
    });
  }

  summary(): Promise<EnvironmentSummary> {
    return this.authRequest(`/v1/environments/${this.environment.environmentID}`);
  }

  createPairing(role: RemoteRole): Promise<{ pairingURL: string; expiresAt: string }> {
    return this.authRequest(`/v1/environments/${this.environment.environmentID}/pairings`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ role }),
    });
  }

  async revokeMember(memberID: string): Promise<void> {
    await this.authRequest(`/v1/environments/${this.environment.environmentID}/members/${memberID}`, {
      method: "DELETE",
    });
  }

  async updatePush(pushToken: string | undefined, preferences: NotificationPreferences): Promise<void> {
    await this.authRequest("/v1/devices/push", {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        pushToken,
        notifyAlerts: preferences.alerts,
        notifyPresence: preferences.presence,
        notifyCommands: preferences.commands,
      }),
    });
  }

  private async authRequest<T>(path: string, options: RequestInit = {}, retry = true): Promise<T> {
    if (new Date(this.environment.accessExpiresAt).getTime() - Date.now() < 30_000) await this.refresh();
    try {
      return await rawRequest<T>(`${this.environment.relayURL}${path}`, {
        ...options,
        headers: { ...options.headers, authorization: `Bearer ${this.environment.accessToken}` },
      });
    } catch (error) {
      if (retry && error instanceof RemoteApiError && error.status === 401) {
        await this.refresh();
        return this.authRequest(path, options, false);
      }
      throw error;
    }
  }

  private refresh(): Promise<TokenUpdate> {
    if (!this.refreshPromise) {
      this.refreshPromise = rawRequest<TokenUpdate>(`${this.environment.relayURL}/v1/sessions/refresh`, {
        method: "POST",
        headers: { authorization: `Bearer ${this.environment.refreshToken}` },
      })
        .then(async (tokens) => {
          this.environment = { ...this.environment, ...tokens };
          await this.onTokens(tokens);
          return tokens;
        })
        .finally(() => {
          this.refreshPromise = null;
        });
    }
    return this.refreshPromise;
  }
}

async function rawRequest<T>(url: string, options: RequestInit = {}): Promise<T> {
  let response: Response;
  try {
    response = await fetch(url, { ...options, signal: AbortSignal.timeout(15_000) });
  } catch {
    throw new RemoteApiError("MacScope Remote could not reach the relay.", 0, "network_error");
  }
  if (!response.ok) {
    const value = (await response.json().catch(() => ({}))) as { message?: string; code?: string };
    throw new RemoteApiError(value.message ?? `Relay returned HTTP ${response.status}.`, response.status, value.code ?? "http_error");
  }
  if (response.status === 204) return undefined as T;
  return (await response.json()) as T;
}
