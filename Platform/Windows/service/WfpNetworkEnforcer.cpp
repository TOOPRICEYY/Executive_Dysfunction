#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <fwpmu.h>
#include <rpc.h>
#include <string>
#include "WfpNetworkEnforcer.h"

namespace {
// Stable identities let an administrator audit ownership in Windows Firewall
// tooling and let upgrades replace only this product's filters.
const GUID kProviderKey =
    {0x2b50ee9d, 0x4d57, 0x4875, {0xb0, 0xf7, 0x34, 0xec, 0xa2, 0x79, 0x51, 0x06}};
const GUID kSubLayerKey =
    {0xc12a67c4, 0x7ed0, 0x4d5e, {0x95, 0x64, 0x4e, 0x47, 0xe2, 0xe8, 0x54, 0x11}};

bool IsSuccessOrExists(DWORD result) {
    return result == ERROR_SUCCESS || result == FWP_E_ALREADY_EXISTS;
}

bool EnsureProviderAndSubLayer(HANDLE engine) {
    FWPM_PROVIDER0 provider{};
    provider.providerKey = kProviderKey;
    provider.displayData.name = const_cast<wchar_t*>(L"Executive Dysfunction Enforcement");
    provider.displayData.description = const_cast<wchar_t*>(
        L"Administrator-authorized application network enforcement");
    provider.flags = FWPM_PROVIDER_FLAG_PERSISTENT;
    if (!IsSuccessOrExists(::FwpmProviderAdd0(engine, &provider, nullptr))) return false;

    FWPM_SUBLAYER0 subLayer{};
    subLayer.subLayerKey = kSubLayerKey;
    subLayer.displayData.name = const_cast<wchar_t*>(L"Executive Dysfunction ALE blocks");
    subLayer.providerKey = const_cast<GUID*>(&kProviderKey);
    subLayer.flags = FWPM_SUBLAYER_FLAG_PERSISTENT;
    subLayer.weight = 0x7000;
    return IsSuccessOrExists(::FwpmSubLayerAdd0(engine, &subLayer, nullptr));
}

bool DeleteOwnedFilters(HANDLE engine) {
    FWPM_FILTER_ENUM_TEMPLATE0 query{};
    query.providerKey = const_cast<GUID*>(&kProviderKey);
    HANDLE enumeration = nullptr;
    if (::FwpmFilterCreateEnumHandle0(engine, &query, &enumeration) != ERROR_SUCCESS) return false;

    bool success = true;
    for (;;) {
        FWPM_FILTER0** filters = nullptr;
        UINT32 count = 0;
        const DWORD result = ::FwpmFilterEnum0(engine, enumeration, 64, &filters, &count);
        if (result != ERROR_SUCCESS) { success = false; break; }
        if (count == 0) { ::FwpmFreeMemory0(reinterpret_cast<void**>(&filters)); break; }
        for (UINT32 index = 0; index < count; ++index) {
            if (::FwpmFilterDeleteById0(engine, filters[index]->filterId) != ERROR_SUCCESS) {
                success = false;
            }
        }
        ::FwpmFreeMemory0(reinterpret_cast<void**>(&filters));
        if (!success) break;
    }
    ::FwpmFilterDestroyEnumHandle0(engine, enumeration);
    return success;
}

bool AddApplicationBlock(HANDLE engine, const wchar_t* path, const GUID& layer) {
    FWP_BYTE_BLOB* appIdentifier = nullptr;
    if (::FwpmGetAppIdFromFileName0(path, &appIdentifier) != ERROR_SUCCESS) return false;

    FWPM_FILTER_CONDITION0 condition{};
    condition.fieldKey = FWPM_CONDITION_ALE_APP_ID;
    condition.matchType = FWP_MATCH_EQUAL;
    condition.conditionValue.type = FWP_BYTE_BLOB_TYPE;
    condition.conditionValue.byteBlob = appIdentifier;

    FWPM_FILTER0 filter{};
    filter.displayData.name = const_cast<wchar_t*>(L"Executive Dysfunction application network block");
    filter.providerKey = const_cast<GUID*>(&kProviderKey);
    filter.layerKey = layer;
    filter.subLayerKey = kSubLayerKey;
    filter.flags = FWPM_FILTER_FLAG_PERSISTENT | FWPM_FILTER_FLAG_CLEAR_ACTION_RIGHT;
    filter.numFilterConditions = 1;
    filter.filterCondition = &condition;
    filter.action.type = FWP_ACTION_BLOCK;
    filter.weight.type = FWP_EMPTY;

    const DWORD result = ::FwpmFilterAdd0(engine, &filter, nullptr, nullptr);
    ::FwpmFreeMemory0(reinterpret_cast<void**>(&appIdentifier));
    return result == ERROR_SUCCESS;
}
} // namespace

bool ReplacePersistentWfpApplicationBlocks(const ED_GUARD_POLICY& policy) {
    HANDLE engine = nullptr;
    if (::FwpmEngineOpen0(nullptr, RPC_C_AUTHN_WINNT, nullptr, nullptr, &engine) != ERROR_SUCCESS) {
        return false;
    }

    bool success = ::FwpmTransactionBegin0(engine, 0) == ERROR_SUCCESS;
    if (success) success = EnsureProviderAndSubLayer(engine);
    if (success) success = DeleteOwnedFilters(engine);
    for (unsigned long index = 0; success && index < policy.ruleCount; ++index) {
        const auto* path = policy.rules[index].path;
        success = path[0] != L'\0'
            && AddApplicationBlock(engine, path, FWPM_LAYER_ALE_AUTH_CONNECT_V4)
            && AddApplicationBlock(engine, path, FWPM_LAYER_ALE_AUTH_CONNECT_V6);
    }

    if (success) {
        success = ::FwpmTransactionCommit0(engine) == ERROR_SUCCESS;
    } else {
        ::FwpmTransactionAbort0(engine);
    }
    ::FwpmEngineClose0(engine);
    return success;
}
