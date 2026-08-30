import * as SecureStore from "expo-secure-store";
import type { NotificationPreferences, StoredEnvironment } from "./types";

const ENVIRONMENTS_KEY = "macscope.remote.environments.v1";
const ACTIVE_KEY = "macscope.remote.active-environment.v1";
const notificationKey = (environmentID: string) => `macscope.remote.notifications.v1.${environmentID}`;

export const remoteStorage = {
  async environments(): Promise<StoredEnvironment[]> {
    const raw = await SecureStore.getItemAsync(ENVIRONMENTS_KEY);
    if (!raw) return [];
    try {
      const parsed: unknown = JSON.parse(raw);
      return Array.isArray(parsed) ? (parsed as StoredEnvironment[]) : [];
    } catch {
      return [];
    }
  },

  async saveEnvironment(environment: StoredEnvironment): Promise<void> {
    const values = await this.environments();
    const next = [...values.filter((value) => value.environmentID !== environment.environmentID), environment];
    await SecureStore.setItemAsync(ENVIRONMENTS_KEY, JSON.stringify(next), {
      keychainAccessible: SecureStore.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY,
    });
    await SecureStore.setItemAsync(ACTIVE_KEY, environment.environmentID);
  },

  async removeEnvironment(environmentID: string): Promise<void> {
    const values = (await this.environments()).filter((value) => value.environmentID !== environmentID);
    await SecureStore.setItemAsync(ENVIRONMENTS_KEY, JSON.stringify(values), {
      keychainAccessible: SecureStore.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY,
    });
    if ((await this.activeEnvironmentID()) === environmentID) {
      if (values[0]) await SecureStore.setItemAsync(ACTIVE_KEY, values[0].environmentID);
      else await SecureStore.deleteItemAsync(ACTIVE_KEY);
    }
    await SecureStore.deleteItemAsync(notificationKey(environmentID));
  },

  activeEnvironmentID: () => SecureStore.getItemAsync(ACTIVE_KEY),
  setActiveEnvironmentID: (environmentID: string) => SecureStore.setItemAsync(ACTIVE_KEY, environmentID),
  async notificationPreferences(environmentID: string): Promise<NotificationPreferences> {
    const raw = await SecureStore.getItemAsync(notificationKey(environmentID));
    if (!raw) return { alerts: true, presence: true, commands: true };
    try {
      return JSON.parse(raw) as NotificationPreferences;
    } catch {
      return { alerts: true, presence: true, commands: true };
    }
  },
  setNotificationPreferences: (environmentID: string, value: NotificationPreferences) =>
    SecureStore.setItemAsync(notificationKey(environmentID), JSON.stringify(value), {
      keychainAccessible: SecureStore.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY,
    }),
};
