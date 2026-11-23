import { BridgeControlStatus } from './bridge-types.js';

export function escapeHtml(input: unknown): string {
  return String(input ?? '').replace(/[&<>"']/g, (ch) => {
    switch (ch) {
      case '&':
        return '&amp;';
      case '<':
        return '&lt;';
      case '>':
        return '&gt;';
      case '"':
        return '&quot;';
      default:
        return '&#39;';
    }
  });
}

export interface StatusBarViewModel {
  text: string;
  isWarning: boolean;
}

export function computeStatusBarViewModel(st: BridgeControlStatus): StatusBarViewModel {
  const count = st.connectedClients?.total ?? 0;
  const pending = st.pendingApprovals?.length ?? 0;
  if (pending > 0) {
    return {
      text: `$(bell-dot) AGY Remote (${pending} approval)`,
      isWarning: true,
    };
  }
  return {
    text: count > 0 ? `$(radio-tower) AGY Remote (${count})` : `$(broadcast) AGY Remote :${st.port}`,
    isWarning: false,
  };
}

