// The redirect callouts.
//
// A filter matches one application ID and carries a provider context naming the
// address that application's connections must originate from. This file reads
// that address and writes it into the connection or bind request. It makes no
// policy decisions of its own.

#include <ntddk.h>
#include <ndis.h>

#include <fwpsk.h>
#include <fwpmk.h>
#include <netiodef.h>

#include "phantrix_split_tunnel_public.h"

namespace {

constexpr UINT8 kTcpProtocol = 6;

struct RedirectAddress {
  ADDRESS_FAMILY family;
  union {
    IN_ADDR v4;
    IN6_ADDR v6;
  } address;
};

bool ReadRedirectAddress(const FWPM_PROVIDER_CONTEXT* context,
                         RedirectAddress* result) {
  result->family = AF_UNSPEC;
  if (context == nullptr || context->type != FWPM_GENERAL_CONTEXT ||
      context->dataBuffer == nullptr || context->dataBuffer->data == nullptr) {
    return false;
  }
  const auto* data =
      reinterpret_cast<const PHANTRIX_REDIRECT_DATA*>(
          context->dataBuffer->data);
  if (data->address_family == AF_INET) {
    result->family = AF_INET;
    result->address.v4 = data->address.v4;
    return true;
  }
  if (data->address_family == AF_INET6) {
    result->family = AF_INET6;
    result->address.v6 = data->address.v6;
    return true;
  }
  return false;
}

void ApplyAddress(SOCKADDR_STORAGE& storage, const RedirectAddress& address) {
  if (address.family == AF_INET) {
    auto* value = reinterpret_cast<SOCKADDR_IN*>(&storage);
    value->sin_family = AF_INET;
    value->sin_addr = address.address.v4;
    return;
  }
  auto* value = reinterpret_cast<SOCKADDR_IN6*>(&storage);
  value->sin6_family = AF_INET6;
  value->sin6_addr = address.address.v6;
}

bool IsLocalV4(const IN_ADDR& address) {
  auto* value = const_cast<IN_ADDR*>(&address);
  return IN4_IS_ADDR_LOOPBACK(value) || IN4_IS_ADDR_LINKLOCAL(value) ||
         IN4_IS_ADDR_RFC1918(value) || IN4_IS_ADDR_MC_LINKLOCAL(value) ||
         IN4_IS_ADDR_BROADCAST(value) || IN4_IS_ADDR_MC_ADMINLOCAL(value);
}

bool IsTeredo(const IN6_ADDR& address) {
  return address.u.Byte[0] == 0x20 && address.u.Byte[1] == 0x01 &&
         address.u.Byte[2] == 0x00 && address.u.Byte[3] == 0x00;
}

bool IsLocalV6(const IN6_ADDR& address) {
  auto* value = const_cast<IN6_ADDR*>(&address);
  return IN6_IS_ADDR_UNSPECIFIED(value) || IN6_IS_ADDR_LOOPBACK(value) ||
         IN6_IS_ADDR_LINKLOCAL(value) || IN6_IS_ADDR_SITELOCAL(value) ||
         IN6_IS_ADDR_MULTICAST(value) || IsTeredo(address) ||
         (value->u.Byte[0] & 0xFE) == 0xFC;
}

bool RemoteIsLocal(const FWPS_INCOMING_VALUES* values, bool ipv4) {
  if (ipv4) {
    IN_ADDR address = {};
    address.S_un.S_addr =
        RtlUlongByteSwap(values
                             ->incomingValue
                                 [FWPS_FIELD_ALE_CONNECT_REDIRECT_V4_IP_REMOTE_ADDRESS]
                             .value.uint32);
    return IsLocalV4(address);
  }
  const auto* bytes =
      values
          ->incomingValue[FWPS_FIELD_ALE_CONNECT_REDIRECT_V6_IP_REMOTE_ADDRESS]
          .value.byteArray16;
  if (bytes == nullptr) {
    return true;
  }
  IN6_ADDR address = {};
  RtlCopyMemory(&address, bytes->byteArray16, sizeof(address));
  return IsLocalV6(address);
}

UINT32 ConnectFlags(const FWPS_INCOMING_VALUES* values, bool ipv4) {
  return ipv4
             ? values
                   ->incomingValue[FWPS_FIELD_ALE_CONNECT_REDIRECT_V4_FLAGS]
                   .value.uint32
             : values
                   ->incomingValue[FWPS_FIELD_ALE_CONNECT_REDIRECT_V6_FLAGS]
                   .value.uint32;
}

UINT32 BindFlags(const FWPS_INCOMING_VALUES* values, bool ipv4) {
  return ipv4
             ? values->incomingValue[FWPS_FIELD_ALE_BIND_REDIRECT_V4_FLAGS]
                   .value.uint32
             : values->incomingValue[FWPS_FIELD_ALE_BIND_REDIRECT_V6_FLAGS]
                   .value.uint32;
}

UINT8 BindProtocol(const FWPS_INCOMING_VALUES* values, bool ipv4) {
  return ipv4
             ? values
                   ->incomingValue[FWPS_FIELD_ALE_BIND_REDIRECT_V4_IP_PROTOCOL]
                   .value.uint8
             : values
                   ->incomingValue[FWPS_FIELD_ALE_BIND_REDIRECT_V6_IP_PROTOCOL]
                   .value.uint8;
}

}  // namespace

void NTAPI RedirectTcpConnection(
    IN const FWPS_INCOMING_VALUES* inFixedValues,
    IN const FWPS_INCOMING_METADATA_VALUES* inMetadataValues,
    IN OUT void* layerData, IN const void* classifyContext,
    IN const FWPS_FILTER* filter, IN UINT64 flowContext,
    IN OUT FWPS_CLASSIFY_OUT* classifyOut) {
  UNREFERENCED_PARAMETER(inMetadataValues);
  UNREFERENCED_PARAMETER(layerData);
  UNREFERENCED_PARAMETER(flowContext);

  classifyOut->actionType = FWP_ACTION_PERMIT;
  if (inFixedValues == nullptr || filter == nullptr ||
      (classifyOut->rights & FWPS_RIGHT_ACTION_WRITE) == 0) {
    return;
  }
  const bool ipv4 =
      inFixedValues->layerId == FWPS_LAYER_ALE_CONNECT_REDIRECT_V4;
  const bool ipv6 =
      inFixedValues->layerId == FWPS_LAYER_ALE_CONNECT_REDIRECT_V6;
  if (!ipv4 && !ipv6) {
    return;
  }
  if ((ConnectFlags(inFixedValues, ipv4) &
       FWP_CONDITION_FLAG_IS_REAUTHORIZE) != 0) {
    return;
  }
  if (RemoteIsLocal(inFixedValues, ipv4)) {
    return;
  }

  RedirectAddress address = {};
  if (!ReadRedirectAddress(filter->providerContext, &address) ||
      (ipv4 && address.family != AF_INET) ||
      (ipv6 && address.family != AF_INET6)) {
    return;
  }

  UINT64 handle = 0;
  FWPS_CONNECT_REQUEST* request = nullptr;
  __try {
    NTSTATUS status = FwpsAcquireClassifyHandle(
        const_cast<void*>(classifyContext), 0, &handle);
    if (!NT_SUCCESS(status)) {
      return;
    }
    status = FwpsAcquireWritableLayerDataPointer(
        handle, filter->filterId, 0, reinterpret_cast<void**>(&request),
        classifyOut);
    if (!NT_SUCCESS(status) || request == nullptr) {
      return;
    }
    // Only the source address changes; the destination and port stay exactly
    // as the application asked for them.
    ApplyAddress(request->localAddressAndPort, address);
  } __finally {
    if (request != nullptr) {
      FwpsApplyModifiedLayerData(handle, request, 0);
    }
    if (handle != 0) {
      FwpsReleaseClassifyHandle(handle);
    }
  }
}

void NTAPI RedirectUdpOrBind(
    IN const FWPS_INCOMING_VALUES* inFixedValues,
    IN const FWPS_INCOMING_METADATA_VALUES* inMetadataValues,
    IN OUT void* layerData, IN const void* classifyContext,
    IN const FWPS_FILTER* filter, IN UINT64 flowContext,
    IN OUT FWPS_CLASSIFY_OUT* classifyOut) {
  UNREFERENCED_PARAMETER(inMetadataValues);
  UNREFERENCED_PARAMETER(layerData);
  UNREFERENCED_PARAMETER(flowContext);

  classifyOut->actionType = FWP_ACTION_PERMIT;
  if (inFixedValues == nullptr || filter == nullptr ||
      (classifyOut->rights & FWPS_RIGHT_ACTION_WRITE) == 0) {
    return;
  }
  const bool ipv4 = inFixedValues->layerId == FWPS_LAYER_ALE_BIND_REDIRECT_V4;
  const bool ipv6 = inFixedValues->layerId == FWPS_LAYER_ALE_BIND_REDIRECT_V6;
  if (!ipv4 && !ipv6) {
    return;
  }
  if ((BindFlags(inFixedValues, ipv4) &
       FWP_CONDITION_FLAG_IS_REAUTHORIZE) != 0) {
    return;
  }
  // TCP connects are handled by the connect-redirect callout. Binding a TCP
  // socket to a local address happens before the destination is known and is
  // not what decides its route.
  if (BindProtocol(inFixedValues, ipv4) == kTcpProtocol) {
    return;
  }

  RedirectAddress address = {};
  if (!ReadRedirectAddress(filter->providerContext, &address) ||
      (ipv4 && address.family != AF_INET) ||
      (ipv6 && address.family != AF_INET6)) {
    return;
  }

  UINT64 handle = 0;
  FWPS_BIND_REQUEST* request = nullptr;
  __try {
    NTSTATUS status = FwpsAcquireClassifyHandle(
        const_cast<void*>(classifyContext), 0, &handle);
    if (!NT_SUCCESS(status)) {
      return;
    }
    status = FwpsAcquireWritableLayerDataPointer(
        handle, filter->filterId, 0, reinterpret_cast<void**>(&request),
        classifyOut);
    if (!NT_SUCCESS(status) || request == nullptr) {
      return;
    }
    ApplyAddress(request->localAddressAndPort, address);
  } __finally {
    if (request != nullptr) {
      FwpsApplyModifiedLayerData(handle, request, 0);
    }
    if (handle != 0) {
      FwpsReleaseClassifyHandle(handle);
    }
  }
}
