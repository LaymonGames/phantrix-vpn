// The Phantrix split-tunnel callout driver.
//
// ## What it does
//
// Four WFP callouts, and nothing else:
//
//   * ALE_CONNECT_REDIRECT_V4/V6 for TCP connections.
//   * ALE_BIND_REDIRECT_V4/V6 for UDP and for sockets that bind explicitly.
//
// The user-mode agent creates the filters and attaches a provider context
// containing the address the connection should originate from. This driver
// reads that context and rewrites the connection's local address. It stores no
// policy, opens no device and exposes no IOCTL: the absence of state is what
// makes a crashed agent harmless.
//
// ## Why the address rewrite works
//
// Windows chooses the outgoing interface from the source address when a socket
// is explicitly bound. Writing the tunnel address into the connection request
// makes the stack route the connection through the Wintun adapter; writing the
// physical address makes it use the normal connection. That is the whole
// mechanism behind both include and exclude mode.
//
// ## Attribution
//
// The redirect sequence is adapted from Proton VPN's GPL-3.0 Windows callout
// driver (ProtonVPN/win-app, src/ProtonVPN.CalloutDriver), which solved the same
// documented WFP problem. This file is smaller: it keeps only the redirect
// callouts, drops their DNS injection path, and has no service protocol.

#include <ntddk.h>
#include <ndis.h>

#include <fwpsk.h>
#include <fwpmk.h>

#include "phantrix_split_tunnel_public.h"

void NTAPI RedirectTcpConnection(
    IN const FWPS_INCOMING_VALUES* inFixedValues,
    IN const FWPS_INCOMING_METADATA_VALUES* inMetadataValues,
    IN OUT void* layerData, IN const void* classifyContext,
    IN const FWPS_FILTER* filter, IN UINT64 flowContext,
    IN OUT FWPS_CLASSIFY_OUT* classifyOut);

void NTAPI RedirectUdpOrBind(
    IN const FWPS_INCOMING_VALUES* inFixedValues,
    IN const FWPS_INCOMING_METADATA_VALUES* inMetadataValues,
    IN OUT void* layerData, IN const void* classifyContext,
    IN const FWPS_FILTER* filter, IN UINT64 flowContext,
    IN OUT FWPS_CLASSIFY_OUT* classifyOut);

namespace {

PDEVICE_OBJECT g_device = nullptr;
UINT32 g_registration = 0;

NTSTATUS NTAPI CalloutNotify(IN FWPS_CALLOUT_NOTIFY_TYPE notify_type,
                             IN const GUID* filter_key,
                             IN FWPS_FILTER* filter) {
  UNREFERENCED_PARAMETER(notify_type);
  UNREFERENCED_PARAMETER(filter_key);
  UNREFERENCED_PARAMETER(filter);
  return STATUS_SUCCESS;
}

NTSTATUS RegisterCallout(const GUID& key,
                         FWPS_CALLOUT_CLASSIFY_FN classify) {
  FWPS_CALLOUT callout = {};
  callout.calloutKey = key;
  callout.classifyFn = classify;
  callout.notifyFn = CalloutNotify;
  callout.flowDeleteFn = nullptr;
  return FwpsCalloutRegister(g_device, &callout, &g_registration);
}

void UnregisterCallout(const GUID& key) {
  (void)FwpsCalloutUnregisterByKey(&key);
}

}  // namespace

NTSTATUS DriverEntry(IN PDRIVER_OBJECT driver_object,
                     IN PUNICODE_STRING registry_path) {
  UNREFERENCED_PARAMETER(registry_path);

  // The callouts only ever touch non-paged memory, and the driver never waits
  // at PASSIVE_LEVEL for user-mode work.
  ExInitializeDriverRuntime(DrvRtPoolNxOptIn);

  UNICODE_STRING device_name;
  RtlInitUnicodeString(&device_name, L"\\Device\\PhantrixSplitTunnel");
  NTSTATUS status = IoCreateDevice(
      driver_object, 0, &device_name, FILE_DEVICE_UNKNOWN,
      FILE_DEVICE_SECURE_OPEN, FALSE, &g_device);
  if (!NT_SUCCESS(status)) {
    return status;
  }

  UNICODE_STRING symbolic_name;
  RtlInitUnicodeString(&symbolic_name,
                       L"\\DosDevices\\PhantrixSplitTunnel");
  status = IoCreateSymbolicLink(&symbolic_name, &device_name);
  if (!NT_SUCCESS(status)) {
    IoDeleteDevice(g_device);
    g_device = nullptr;
    return status;
  }

  driver_object->DriverUnload = [](PDRIVER_OBJECT object) {
    UnregisterCallout(PHANTRIX_CONNECT_REDIRECT_V4_CALLOUT);
    UnregisterCallout(PHANTRIX_CONNECT_REDIRECT_V6_CALLOUT);
    UnregisterCallout(PHANTRIX_BIND_REDIRECT_V4_CALLOUT);
    UnregisterCallout(PHANTRIX_BIND_REDIRECT_V6_CALLOUT);
    UNICODE_STRING name;
    RtlInitUnicodeString(&name, L"\\DosDevices\\PhantrixSplitTunnel");
    IoDeleteSymbolicLink(&name);
    if (g_device != nullptr) {
      IoDeleteDevice(g_device);
      g_device = nullptr;
    }
  };

  const struct {
    const GUID& key;
    FWPS_CALLOUT_CLASSIFY_FN classify;
  } callouts[] = {
      {PHANTRIX_CONNECT_REDIRECT_V4_CALLOUT, RedirectTcpConnection},
      {PHANTRIX_CONNECT_REDIRECT_V6_CALLOUT, RedirectTcpConnection},
      {PHANTRIX_BIND_REDIRECT_V4_CALLOUT, RedirectUdpOrBind},
      {PHANTRIX_BIND_REDIRECT_V6_CALLOUT, RedirectUdpOrBind},
  };
  for (const auto& entry : callouts) {
    status = RegisterCallout(entry.key, entry.classify);
    if (!NT_SUCCESS(status)) {
      driver_object->DriverUnload(driver_object);
      return status;
    }
  }
  return STATUS_SUCCESS;
}
