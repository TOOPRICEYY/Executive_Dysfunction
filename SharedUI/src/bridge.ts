import {
  isSnapshot,
  isChallenge,
  protocolVersion,
  type Adapter,
  type Command,
  type Reply,
  type ReplyEnvelope,
  type RequestEnvelope,
} from "./contract.ts";

/** Transport is injected, never inferred from an arbitrary page URL. */
export interface Transport {
  post(request: RequestEnvelope): void;
  subscribe(receive: (reply: unknown) => void): () => void;
}
export function createBridge(transport: Transport, timeout = 15_000): Adapter {
  const pending = new Map<
    string,
    {
      resolve: (reply: Reply) => void;
      reject: (error: Error) => void;
      timer: ReturnType<typeof setTimeout>;
    }
  >();
  let disposed = false;
  const unsubscribe = transport.subscribe((value) => {
    if (!value || typeof value !== "object") return;
    const reply = value as ReplyEnvelope;
    if (reply.version !== protocolVersion || typeof reply.id !== "string")
      return;
    const call = pending.get(reply.id);
    if (!call) return;
    clearTimeout(call.timer);
    pending.delete(reply.id);
    if (reply.ok !== true) {
      call.reject(
        new Error(
          typeof reply.error === "string"
            ? reply.error
            : "The device rejected this request.",
        ),
      );
      return;
    }
    const result = reply.result;
    if (
      !result ||
      typeof result !== "object" ||
      (result.snapshot !== undefined && !isSnapshot(result.snapshot)) ||
      (result.challenge !== undefined && !isChallenge(result.challenge)) ||
      (result.applications !== undefined &&
        (!Array.isArray(result.applications) ||
          result.applications.some((v) => typeof v !== "string"))) ||
      (result.message !== undefined && typeof result.message !== "string") ||
      (result.applicationSummary !== undefined &&
        typeof result.applicationSummary !== "string") ||
      (result.selectionToken !== undefined &&
        typeof result.selectionToken !== "string")
    ) {
      call.reject(
        new Error(
          "The device returned an incompatible response. No change has been assumed.",
        ),
      );
      return;
    }
    call.resolve(result);
  });
  return {
    send(command: Command) {
      if (disposed)
        return Promise.reject(new Error("The device connection is closed."));
      return new Promise<Reply>((resolve, reject) => {
        const id = crypto.randomUUID();
        const timer = setTimeout(
          () => {
            pending.delete(id);
            // Never automatically retry a mutation: it may already have taken effect.
            reject(
              new Error(
                "The device did not acknowledge this request. Refresh status before trying again.",
              ),
            );
          },
          command.type === "pickApplications"
            ? Math.max(timeout, 600_000)
            : timeout,
        );
        pending.set(id, { resolve, reject, timer });
        try {
          transport.post({ version: protocolVersion, id, command });
        } catch (error) {
          clearTimeout(timer);
          pending.delete(id);
          reject(error);
        }
      });
    },
    dispose() {
      disposed = true;
      unsubscribe();
      for (const call of pending.values()) {
        clearTimeout(call.timer);
        call.reject(new Error("The device connection was closed."));
      }
      pending.clear();
    },
  };
}

declare global {
  interface Window {
    chrome?: {
      webview?: {
        postMessage(message: unknown): void;
        addEventListener(name: string, fn: (event: MessageEvent) => void): void;
        removeEventListener(
          name: string,
          fn: (event: MessageEvent) => void,
        ): void;
      };
    };
    webkit?: {
      messageHandlers?: { holdfast?: { postMessage(message: unknown): void } };
    };
    holdfastReceive?: (reply: unknown) => void;
  }
}
export function nativeAdapter(): Adapter | null {
  const webview = window.chrome?.webview;
  if (webview)
    return createBridge({
      post: (message) => webview.postMessage(message),
      subscribe(receive) {
        const listener = (event: MessageEvent) => receive(event.data);
        webview.addEventListener("message", listener);
        return () => webview.removeEventListener("message", listener);
      },
    });
  const handler = window.webkit?.messageHandlers?.holdfast;
  if (handler)
    return createBridge({
      post: (message) => handler.postMessage(message),
      subscribe(receive) {
        window.holdfastReceive = receive;
        return () => {
          delete window.holdfastReceive;
        };
      },
    });
  return null;
}
