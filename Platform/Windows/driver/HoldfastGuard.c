#include <ntddk.h>
#include <wdmsec.h>
#include <ntstrsafe.h>
#include "../include/guard_protocol.h"

// Only SYSTEM and local Administrators can replace policy. The service further
// restricts its own control pipe to SYSTEM and the installing administrator.
static const WCHAR kDeviceSddl[] = L"D:P(A;;GA;;;SY)(A;;GA;;;BA)";
static const GUID kDeviceClass =
    {0x22db7253, 0x66bb, 0x4cb1, {0x93, 0x4f, 0x2e, 0xa5, 0x1f, 0x55, 0x83, 0x61}};

static EX_PUSH_LOCK gPolicyLock;
static ED_GUARD_POLICY gPolicy;
static PDEVICE_OBJECT gDeviceObject;
static UNICODE_STRING gSymbolicLink;

static BOOLEAN PathEqualsInsensitive(PCUNICODE_STRING image, const WCHAR *configured)
{
    UNICODE_STRING expected;
    RtlInitUnicodeString(&expected, configured);
    return image && image->Buffer && RtlEqualUnicodeString(image, &expected, TRUE);
}

static VOID ProcessNotify(
    PEPROCESS Process,
    HANDLE ProcessId,
    PPS_CREATE_NOTIFY_INFO CreateInfo)
{
    UNREFERENCED_PARAMETER(Process);
    UNREFERENCED_PARAMETER(ProcessId);
    if (!CreateInfo || !CreateInfo->ImageFileName) return;

    ExAcquirePushLockShared(&gPolicyLock);
    ULONG count = min(gPolicy.ruleCount, ED_GUARD_MAX_RULES);
    for (ULONG index = 0; index < count; ++index) {
        if (PathEqualsInsensitive(CreateInfo->ImageFileName, gPolicy.rules[index].path)) {
            CreateInfo->CreationStatus = STATUS_ACCESS_DISABLED_BY_POLICY_OTHER;
            break;
        }
    }
    ExReleasePushLockShared(&gPolicyLock);
}

static NTSTATUS CompleteIrp(PIRP irp, NTSTATUS status, ULONG_PTR information)
{
    irp->IoStatus.Status = status;
    irp->IoStatus.Information = information;
    IoCompleteRequest(irp, IO_NO_INCREMENT);
    return status;
}

static NTSTATUS DispatchCreateClose(PDEVICE_OBJECT device, PIRP irp)
{
    UNREFERENCED_PARAMETER(device);
    return CompleteIrp(irp, STATUS_SUCCESS, 0);
}

static NTSTATUS DispatchDeviceControl(PDEVICE_OBJECT device, PIRP irp)
{
    UNREFERENCED_PARAMETER(device);
    PIO_STACK_LOCATION stack = IoGetCurrentIrpStackLocation(irp);
    if (stack->Parameters.DeviceIoControl.IoControlCode != IOCTL_ED_GUARD_REPLACE_POLICY) {
        return CompleteIrp(irp, STATUS_INVALID_DEVICE_REQUEST, 0);
    }
    if (stack->Parameters.DeviceIoControl.InputBufferLength != sizeof(ED_GUARD_POLICY)) {
        return CompleteIrp(irp, STATUS_INFO_LENGTH_MISMATCH, 0);
    }

    const ED_GUARD_POLICY *candidate = (const ED_GUARD_POLICY *)irp->AssociatedIrp.SystemBuffer;
    if (!candidate || candidate->version != 1 || candidate->revision == 0
        || candidate->ruleCount > ED_GUARD_MAX_RULES) {
        return CompleteIrp(irp, STATUS_INVALID_PARAMETER, 0);
    }
    for (ULONG index = 0; index < candidate->ruleCount; ++index) {
        if (candidate->rules[index].path[0] == L'\0'
            || candidate->rules[index].path[ED_GUARD_MAX_PATH_CHARS - 1] != L'\0') {
            return CompleteIrp(irp, STATUS_INVALID_PARAMETER, 0);
        }
    }

    // IOCTL dispatch does not inherit the process-notify callback's critical
    // region. Push locks require normal kernel APCs to be disabled here.
    KeEnterCriticalRegion();
    ExAcquirePushLockExclusive(&gPolicyLock);
    // Reject replay/rollback. A deliberate recovery uninstall unloads the
    // driver; ordinary policy updates can only move monotonically forward.
    // Equal revisions remain writable so the service can retry after a crash
    // and publish a new active-rule snapshot at a schedule boundary without
    // changing the authenticated policy revision. Older revisions fail.
    if (candidate->revision < gPolicy.revision) {
        ExReleasePushLockExclusive(&gPolicyLock);
        KeLeaveCriticalRegion();
        return CompleteIrp(irp, STATUS_REVISION_MISMATCH, 0);
    }
    RtlCopyMemory(&gPolicy, candidate, sizeof(gPolicy));
    for (ULONG i = 0; i < gPolicy.ruleCount; ++i) {
        gPolicy.rules[i].path[ED_GUARD_MAX_PATH_CHARS - 1] = L'\0';
    }
    ExReleasePushLockExclusive(&gPolicyLock);
    KeLeaveCriticalRegion();
    return CompleteIrp(irp, STATUS_SUCCESS, 0);
}

static VOID DriverUnload(PDRIVER_OBJECT driver)
{
    UNREFERENCED_PARAMETER(driver);
    PsSetCreateProcessNotifyRoutineEx(ProcessNotify, TRUE);
    IoDeleteSymbolicLink(&gSymbolicLink);
    if (gDeviceObject) IoDeleteDevice(gDeviceObject);
}

NTSTATUS DriverEntry(PDRIVER_OBJECT driver, PUNICODE_STRING registryPath)
{
    UNREFERENCED_PARAMETER(registryPath);
    UNICODE_STRING deviceName;
    UNICODE_STRING sddl;
    RtlInitUnicodeString(&deviceName, L"\\Device\\HoldfastGuard");
    RtlInitUnicodeString(&gSymbolicLink, L"\\DosDevices\\HoldfastGuard");
    RtlInitUnicodeString(&sddl, kDeviceSddl);
    ExInitializePushLock(&gPolicyLock);
    RtlZeroMemory(&gPolicy, sizeof(gPolicy));

    NTSTATUS status = IoCreateDeviceSecure(
        driver, 0, &deviceName, FILE_DEVICE_UNKNOWN, FILE_DEVICE_SECURE_OPEN,
        FALSE, &sddl, &kDeviceClass, &gDeviceObject);
    if (!NT_SUCCESS(status)) return status;

    status = IoCreateSymbolicLink(&gSymbolicLink, &deviceName);
    if (!NT_SUCCESS(status)) {
        IoDeleteDevice(gDeviceObject);
        return status;
    }

    driver->MajorFunction[IRP_MJ_CREATE] = DispatchCreateClose;
    driver->MajorFunction[IRP_MJ_CLOSE] = DispatchCreateClose;
    driver->MajorFunction[IRP_MJ_DEVICE_CONTROL] = DispatchDeviceControl;
    driver->DriverUnload = DriverUnload;

    status = PsSetCreateProcessNotifyRoutineEx(ProcessNotify, FALSE);
    if (!NT_SUCCESS(status)) {
        IoDeleteSymbolicLink(&gSymbolicLink);
        IoDeleteDevice(gDeviceObject);
    }
    return status;
}
