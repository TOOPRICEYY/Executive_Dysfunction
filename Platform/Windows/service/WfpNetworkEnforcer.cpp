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

DWORD EnsureProviderAndSubLayer(HANDLE engine) {
    FWPM_PROVIDER0 provider{};
    provider.providerKey = kProviderKey;
    provider.displayData.name = const_cast<wchar_t*>(L"Holdfast Enforcement");
    provider.displayData.description = const_cast<wchar_t*>(
        L"Administrator-authorized application network enforcement");
    provider.flags = FWPM_PROVIDER_FLAG_PERSISTENT;
    const DWORD providerResult = ::FwpmProviderAdd0(engine, &provider, nullptr);
    if (!IsSuccessOrExists(providerResult)) return providerResult;

    FWPM_SUBLAYER0 subLayer{};
    subLayer.subLayerKey = kSubLayerKey;
    subLayer.displayData.name = const_cast<wchar_t*>(L"Holdfast ALE blocks");
    subLayer.providerKey = const_cast<GUID*>(&kProviderKey);
    subLayer.flags = FWPM_SUBLAYER_FLAG_PERSISTENT;
    subLayer.weight = 0x7000;
    const DWORD subLayerResult = ::FwpmSubLayerAdd0(engine, &subLayer, nullptr);
    return IsSuccessOrExists(subLayerResult) ? ERROR_SUCCESS : subLayerResult;
}

DWORD DeleteOwnedFilters(HANDLE engine) {
    HANDLE enumeration = nullptr;
    // A zero-initialized template has actionMask=0, which Windows rejects
    // with FWP_E_NEVER_MATCH. Enumerate all layers and check ownership before
    // every deletion; never remove another provider's filters.
    DWORD result = ::FwpmFilterCreateEnumHandle0(engine, nullptr, &enumeration);
    if (result != ERROR_SUCCESS) return result;

    DWORD failure = ERROR_SUCCESS;
    for (;;) {
        FWPM_FILTER0** filters = nullptr;
        UINT32 count = 0;
        result = ::FwpmFilterEnum0(engine, enumeration, 64, &filters, &count);
        if (result != ERROR_SUCCESS) { failure = result; break; }
        if (count == 0) { ::FwpmFreeMemory0(reinterpret_cast<void**>(&filters)); break; }
        for (UINT32 index = 0; index < count; ++index) {
            if (!filters[index]->providerKey || !IsEqualGUID(*filters[index]->providerKey, kProviderKey)) continue;
            result = ::FwpmFilterDeleteById0(engine, filters[index]->filterId);
            if (result != ERROR_SUCCESS && failure == ERROR_SUCCESS) failure = result;
        }
        ::FwpmFreeMemory0(reinterpret_cast<void**>(&filters));
        if (failure != ERROR_SUCCESS) break;
    }
    ::FwpmFilterDestroyEnumHandle0(engine, enumeration);
    return failure;
}

DWORD AddApplicationBlock(HANDLE engine, const wchar_t* path, const GUID& layer, UINT64& id) {
    FWP_BYTE_BLOB* appIdentifier = nullptr;
    DWORD result = ::FwpmGetAppIdFromFileName0(path, &appIdentifier);
    if (result != ERROR_SUCCESS) return result;

    FWPM_FILTER_CONDITION0 condition{};
    condition.fieldKey = FWPM_CONDITION_ALE_APP_ID;
    condition.matchType = FWP_MATCH_EQUAL;
    condition.conditionValue.type = FWP_BYTE_BLOB_TYPE;
    condition.conditionValue.byteBlob = appIdentifier;

    FWPM_FILTER0 filter{};
    filter.displayData.name = const_cast<wchar_t*>(L"Holdfast application network block");
    filter.providerKey = const_cast<GUID*>(&kProviderKey);
    filter.layerKey = layer;
    filter.subLayerKey = kSubLayerKey;
    filter.flags = FWPM_FILTER_FLAG_CLEAR_ACTION_RIGHT;
    filter.numFilterConditions = 1;
    filter.filterCondition = &condition;
    filter.action.type = FWP_ACTION_BLOCK;
    filter.weight.type = FWP_EMPTY;

    result = ::FwpmFilterAdd0(engine, &filter, nullptr, &id);
    ::FwpmFreeMemory0(reinterpret_cast<void**>(&appIdentifier));
    return result;
}
} // namespace

WfpReplaceResult RemoveAllOwnedWfpFilters() {
    HANDLE engine = nullptr;
    DWORD result = ::FwpmEngineOpen0(nullptr, RPC_C_AUTHN_WINNT, nullptr, nullptr, &engine);
    if (result != ERROR_SUCCESS) return {false, result, L"engine-open", 0};
    result = ::FwpmTransactionBegin0(engine, 0);
    if (result == ERROR_SUCCESS) result = DeleteOwnedFilters(engine);
    if (result == ERROR_SUCCESS) result = ::FwpmTransactionCommit0(engine);
    else ::FwpmTransactionAbort0(engine);
    ::FwpmEngineClose0(engine);
    return {result == ERROR_SUCCESS, result, L"recover-owned-filters", 0};
}

WfpNetworkEnforcer::~WfpNetworkEnforcer() {
    if (engine_) ::FwpmEngineClose0(engine_);
}

bool WfpNetworkEnforcer::Healthy() const {
    if (!engine_) return false;
    for (UINT64 id : filters_) {
        FWPM_FILTER0* filter = nullptr;
        const DWORD result = ::FwpmFilterGetById0(engine_, id, &filter);
        if (filter) ::FwpmFreeMemory0(reinterpret_cast<void**>(&filter));
        if (result != ERROR_SUCCESS) return false;
    }
    return true;
}

WfpReplaceResult WfpNetworkEnforcer::Replace(const std::vector<std::u16string>& paths) {
    DWORD result = ERROR_SUCCESS;
    if (!engine_) {
        // Register stable audit ownership using a non-dynamic administrative
        // session; only filters belong to the crash-cleaned dynamic session.
        HANDLE setup = nullptr;
        result = ::FwpmEngineOpen0(nullptr, RPC_C_AUTHN_WINNT, nullptr, nullptr, &setup);
        if (result == ERROR_SUCCESS) {
            result = EnsureProviderAndSubLayer(setup);
            ::FwpmEngineClose0(setup);
        }
        if (result != ERROR_SUCCESS) return {false, result, L"provider-sublayer", 0};
        FWPM_SESSION0 session{};
        session.flags = FWPM_SESSION_FLAG_DYNAMIC;
        session.displayData.name = const_cast<wchar_t*>(L"Holdfast recoverable application blocks");
        result = ::FwpmEngineOpen0(nullptr, RPC_C_AUTHN_WINNT, nullptr, &session, &engine_);
        if (result != ERROR_SUCCESS) return {false, result, L"dynamic-engine-open", 0};
    }
    const wchar_t* stage = L"transaction-begin";
    result = ::FwpmTransactionBegin0(engine_, 0);
    if (result != ERROR_SUCCESS) {
        // Expiry/clear must not retain the previous blocks when a session can
        // no longer start transactions. Drop the dynamic session and retry
        // with a fresh handle on the next service tick.
        ::FwpmEngineClose0(engine_); engine_ = nullptr; filters_.clear();
        return {false, result, stage, 0};
    }
    stage = L"delete-previous-dynamic-filters";
    for (UINT64 id : filters_) {
        result = ::FwpmFilterDeleteById0(engine_, id);
        if (result != ERROR_SUCCESS && result != FWP_E_FILTER_NOT_FOUND) break;
        result = ERROR_SUCCESS;
    }
    std::vector<UINT64> added;
    stage = L"resolve-or-add-application";
    for (const auto& path : paths) {
        if (result != ERROR_SUCCESS) break;
        const std::wstring native(path.begin(), path.end());
        for (const GUID* layer : {&FWPM_LAYER_ALE_AUTH_CONNECT_V4, &FWPM_LAYER_ALE_AUTH_CONNECT_V6}) {
            UINT64 id = 0;
            result = AddApplicationBlock(engine_, native.c_str(), *layer, id);
            if (result != ERROR_SUCCESS) break;
            added.push_back(id);
        }
    }
    if (result == ERROR_SUCCESS) {
        stage = L"transaction-commit";
        result = ::FwpmTransactionCommit0(engine_);
    }
    if (result != ERROR_SUCCESS) {
        ::FwpmTransactionAbort0(engine_);
        // A broken BFE/RPC session is not recoverable by keeping its handle.
        // Closing also removes our previous filters, avoiding stale blocking.
        ::FwpmEngineClose0(engine_); engine_ = nullptr; filters_.clear();
        return {false, result, stage, 0};
    }
    filters_ = std::move(added);
    return {true, ERROR_SUCCESS, stage, static_cast<unsigned long>(filters_.size())};
}
