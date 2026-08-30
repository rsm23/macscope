import type { RemoteRole } from "./types";

export const roleCanWrite = (role: RemoteRole | undefined): boolean => role === "operator" || role === "owner";

export const reconnectDelay = (attempt: number): number =>
  Math.min(2 ** Math.min(Math.max(attempt, 1), 5), 30) * 1_000;

export async function requireDeviceAuthentication(
  required: boolean,
  authenticator: {
    hasHardware(): Promise<boolean>;
    isEnrolled(): Promise<boolean>;
    authenticate(): Promise<{ success: boolean }>;
  },
): Promise<void> {
  if (!required) return;
  if (!(await authenticator.hasHardware()) || !(await authenticator.isEnrolled())) {
    throw new Error("Set up Face ID, Touch ID, or a device credential before running sensitive actions.");
  }
  if (!(await authenticator.authenticate()).success) {
    throw new Error("Device authentication was cancelled or failed.");
  }
}
