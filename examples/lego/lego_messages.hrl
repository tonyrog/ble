-ifndef(__LEGO_MESSAGES_HRL__).
-define(__LEGO_MESSAGES_HRL__, true).

%% LEGO Manufacturer ID
-define(LEGO_MANUFACTURER_ID, 16#0397).

%% Message Types
-define(MSG_HUB_PROPERTIES,          16#01).
-define(MSG_HUB_ACTIONS,             16#02).
-define(MSG_HUB_ALERTS,              16#03).
-define(MSG_HUB_ATTACHED_IO,         16#04).
-define(MSG_GENERIC_ERROR,           16#05).
-define(MSG_HW_NETWORK_COMMANDS,     16#08).
-define(MSG_PORT_INFO_REQUEST,       16#21).
-define(MSG_PORT_MODE_INFO_REQUEST,  16#22).
-define(MSG_PORT_INPUT_FORMAT_SETUP, 16#41).
-define(MSG_PORT_INFO,               16#43).
-define(MSG_PORT_VALUE_SINGLE,       16#45).
-define(MSG_PORT_OUTPUT_COMMAND,     16#81).

%% Hub Properties
-define(PROP_ADV_NAME,               16#01).
-define(PROP_BUTTON,                 16#02).
-define(PROP_FW_VERSION,             16#03).
-define(PROP_HW_VERSION,             16#04).
-define(PROP_RSSI,                   16#05).
-define(PROP_BATTERY_VOLTAGE,        16#06).
-define(PROP_BATTERY_TYPE,           16#07).

%% Property Operations
-define(OP_SET,                      16#01).
-define(OP_ENABLE_UPDATES,           16#02).
-define(OP_DISABLE_UPDATES,          16#03).
-define(OP_RESET,                    16#04).
-define(OP_REQUEST_UPDATE,           16#05).
-define(OP_UPDATE,                   16#06).

%% Network command subtypes
-define(NET_CONNECTION_REQUEST, 16#02).  %% Up from device
-define(NET_FAMILY_SET,         16#04).  %% Down to device
-define(NET_FAMILY,             16#07).  %% Up from device
-define(NET_SUBFAMILY,          16#09).  %% Up from device
-define(NET_SUBFAMILY_SET,      16#0A).  %% Down to device
-define(NET_EXT_FAMILY,         16#0C).  %% Up from device
-define(NET_EXT_FAMILY_SET,     16#0D).  %% Down to device

-define(NET_RESET,              16#03).  %% Reset connection

-endif.
