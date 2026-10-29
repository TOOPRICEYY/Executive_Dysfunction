export const labels = {
  blocking: "Blocking",
  allowed: "Allowance window",
  suspended: "Temporarily suspended",
  disabled: "Disabled",
  unsupported: "Not enforced",
  lockdown: "Lockdown",
};
export const when = (iso: string) =>
  new Date(iso).toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
export const duration = (iso: string) =>
  new Date(iso).toLocaleTimeString(undefined, {
    hour: "numeric",
    minute: "2-digit",
  });
