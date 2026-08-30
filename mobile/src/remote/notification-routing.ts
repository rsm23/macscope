export function notificationTarget(data: Record<string, unknown>): {
  environmentID?: string;
  commandID?: string;
  alertID?: string;
  actionID?: string;
  accepted?: string;
  errorCode?: string;
} {
  return {
    environmentID: typeof data.environmentID === "string" ? data.environmentID : undefined,
    commandID: typeof data.commandID === "string" ? data.commandID : undefined,
    alertID: typeof data.envelopeID === "string" ? data.envelopeID : undefined,
    actionID: typeof data.actionID === "string" ? data.actionID : undefined,
    accepted: typeof data.accepted === "string" ? data.accepted : undefined,
    errorCode: typeof data.errorCode === "string" ? data.errorCode : undefined,
  };
}
