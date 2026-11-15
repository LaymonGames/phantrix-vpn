// Values shared by the split-tunnel driver and its user-mode policy agent.
//
// The driver is stateless: it registers four redirect callouts, and the agent
// attaches the redirect address to each filter through a provider context. The
// structure below is the whole contract between the two.
//
// The callout keys are part of that contract. They are fixed so the agent can
// name a callout without an IOCTL, and so a filter left in a WFP dump can be
// matched to this source.

#ifndef PHANTRIX_SPLIT_TUNNEL_PUBLIC_H_
#define PHANTRIX_SPLIT_TUNNEL_PUBLIC_H_

#include <initguid.h>
#include <ws2def.h>
#include <ws2ipdef.h>

// {6d1f2a10-4e7c-4a33-9f22-0c4a6a4f1c01}
DEFINE_GUID(PHANTRIX_CONNECT_REDIRECT_V4_CALLOUT,
            0x6d1f2a10, 0x4e7c, 0x4a33, 0x9f, 0x22, 0x0c, 0x4a, 0x6a, 0x4f,
            0x1c, 0x01);

// {6d1f2a10-4e7c-4a33-9f22-0c4a6a4f1c02}
DEFINE_GUID(PHANTRIX_CONNECT_REDIRECT_V6_CALLOUT,
            0x6d1f2a10, 0x4e7c, 0x4a33, 0x9f, 0x22, 0x0c, 0x4a, 0x6a, 0x4f,
            0x1c, 0x02);

// {6d1f2a10-4e7c-4a33-9f22-0c4a6a4f1c03}
DEFINE_GUID(PHANTRIX_BIND_REDIRECT_V4_CALLOUT,
            0x6d1f2a10, 0x4e7c, 0x4a33, 0x9f, 0x22, 0x0c, 0x4a, 0x6a, 0x4f,
            0x1c, 0x03);

// {6d1f2a10-4e7c-4a33-9f22-0c4a6a4f1c04}
DEFINE_GUID(PHANTRIX_BIND_REDIRECT_V6_CALLOUT,
            0x6d1f2a10, 0x4e7c, 0x4a33, 0x9f, 0x22, 0x0c, 0x4a, 0x6a, 0x4f,
            0x1c, 0x04);

// The provider context attached to each redirect filter. The callout reads the
// address from it and writes it into the connection's local address.
typedef struct PHANTRIX_REDIRECT_DATA_ {
  ADDRESS_FAMILY address_family;
  union {
    IN_ADDR v4;
    IN6_ADDR v6;
  } address;
} PHANTRIX_REDIRECT_DATA;

#endif  // PHANTRIX_SPLIT_TUNNEL_PUBLIC_H_
