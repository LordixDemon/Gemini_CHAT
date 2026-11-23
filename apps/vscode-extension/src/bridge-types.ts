export interface BridgeControlStatus {
  ok: boolean;
  port: number;
  machineId: string;
  machineName: string;
  lanIp: string;
  lanBaseUrl: string;
  lanInterfaces: Array<{ interface: string; address: string; score: number }>;
  pairing: {
    pin: string;
    formattedPin: string;
    expiresAt: number;
    pairingUrl: string;
    qrSvg: string;
  };
  settings: {
    approvalMode: 'observe' | 'ask-mobile' | 'auto-safe';
    preferredLanIp: string;
    cloudflareMode: 'disabled' | 'edge-worker' | 'cloudflared';
    cloudflareEdgeUrl: string;
    cloudflareEdgeSecret: string;
  };
  cloudflare: {
    mode: string;
    status: string;
    lastError: string;
    edgeUrl: string;
    publicPairBaseUrl: string;
    edgeMobileCount: number;
  };
  connectedClients: {
    lanCount: number;
    edgeCount: number;
    total: number;
    lanDevices: Array<{ id: string; name: string; platform: string }>;
  };
  pairedDevices: Array<{ id: string; name: string; platform: string; lastSeenAt: number }>;
  pendingApprovals: Array<{ id: string; toolName: string; summary: string }>;
  pendingChanges?: Array<{
    path: string;
    status: string;
    additions: number;
    deletions: number;
  }>;
  lastTaskCompletedAt?: number;
  lastStopRequestedAt?: number;
  sessions: Array<{ id: string; title: string; status: string; stepCount: number }>;
}

export interface BridgeHandle {
  mode: 'hosted' | 'attached';
  server: {
    stop(): Promise<void>;
    on(event: 'status_changed', cb: (st: BridgeControlStatus) => void): void;
  } | null;
  client: {
    getControlStatus(): Promise<BridgeControlStatus>;
    rotatePin(): Promise<BridgeControlStatus>;
    revokeDevice(deviceId: string): Promise<BridgeControlStatus>;
    updateSettings(patch: Record<string, unknown>): Promise<BridgeControlStatus>;
    decideApproval(payload: Record<string, unknown>): Promise<unknown>;
    saveChanges(paths?: string[]): Promise<BridgeControlStatus>;
    revertChanges(opts?: { paths?: string[]; all?: boolean }): Promise<BridgeControlStatus>;
  };
  initialStatus: BridgeControlStatus;
}

