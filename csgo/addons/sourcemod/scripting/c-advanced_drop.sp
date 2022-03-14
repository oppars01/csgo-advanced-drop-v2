#include <sourcemod>
#include <json>
#include <multicolors>
#include <SteamWorks>
#include <sdktools>
#include <dhooks>
#include <discord>
#include <csgoturkiye>

#define API_URL "https://csgo-turkiye.com/api/csgo-drop-item.php?def_index="

#pragma semicolon 1

public Plugin myinfo = 
{
	name = "Advanced Drop", 
	author = "oppa", 
	description = "Attempts to drop drops for the duration of the map. It sends the falling drops to the discord server in an advanced way.", 
	version = "1.0", 
	url = "csgo-turkiye.com"
};

char s_drop_items[ PLATFORM_MAX_PATH ],s_log_file[ PLATFORM_MAX_PATH ], s_tag_plugin[ 64 ], s_webhook_URL[ 256 ], s_prime_api_key[ 32 ];
Handle h_match_end_drops = null, h_wait_timer = null;
int i_OS = -1, i_play_sound_status;
float f_wait_timer;
bool b_chat_info, b_client_prime_status [ MAXPLAYERS+1 ] = {false , ...};
Address a_drop_for_all_players_patch = Address_Null;

public void OnPluginStart()
{   
    LoadTranslations("c-advanced-drop.phrases.txt");
    GameData h_game_data = LoadGameConfigFile("advanced_drop.games");
    if (!h_game_data)SetFailState("%t", "GameData Error", s_tag_plugin);
    i_OS = h_game_data.GetOffset("OS");
    if(i_OS == -1)SetFailState("%t", "OS Error", s_tag_plugin);
    if(i_OS == 1)StartPrepSDKCall(SDKCall_Raw);
    else StartPrepSDKCall(SDKCall_Static);
    PrepSDKCall_SetFromConf(h_game_data, SDKConf_Signature, "CCSGameRules::RewardMatchEndDrops");
    PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_Plain);
    if (!(h_match_end_drops = EndPrepSDKCall()))SetFailState("%t", "RewardMatchEndDrops Error", s_tag_plugin);
    DynamicDetour dd_record_player_item_drop = DynamicDetour.FromConf(h_game_data, "CCSGameRules::RecordPlayerItemDrop");
    if (!dd_record_player_item_drop)SetFailState("%t", "RecordPlayerItemDrop Error", s_tag_plugin);
    if(!dd_record_player_item_drop.Enable(Hook_Post, Detour_RecordPlayerItemDrop))
	SetFailState("%t", "RecordPlayerItemDrop Error 2", s_tag_plugin);
    a_drop_for_all_players_patch = h_game_data.GetAddress("DropForAllPlayersPatch");
    if(a_drop_for_all_players_patch != Address_Null)
	{
		if((LoadFromAddress(a_drop_for_all_players_patch, NumberType_Int32) & 0xFFFFFF) == 0x1F883)
		{
			a_drop_for_all_players_patch += view_as<Address>(2);
			StoreToAddress(a_drop_for_all_players_patch, 0xFF, NumberType_Int8);
		}else
		{
			a_drop_for_all_players_patch = Address_Null;
			LogError("%t", "DropForAllPlayersPatch Error", s_tag_plugin);
		}
	}
	else LogError("%t", "DropForAllPlayersPatch Error 2", s_tag_plugin);
    delete h_game_data;
    BuildPath(Path_SM, s_log_file, sizeof( s_log_file ), "logs/advanced_drop.log");
    for (int i = 1; i <= MaxClients; i++)if (IsValidClient(i)) ClientPrimeStatus(i);
}

public void OnPluginEnd()
{
	if(a_drop_for_all_players_patch != Address_Null)StoreToAddress(a_drop_for_all_players_patch, 0x01, NumberType_Int8);	
}

public void OnMapStart()
{
    Settings();
    BuildPath( Path_SM, s_drop_items, sizeof( s_drop_items ), "configs/dropitems.cfg" );
    PrecacheSound("ui/panorama/case_awarded_1_uncommon_01.wav");
    CreateTimer(f_wait_timer, TryDropping, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
    PrintToServer("%t", "Drop Active", s_tag_plugin, RoundFloat(f_wait_timer));
}

public void OnClientPostAdminCheck(int client)
{
	ClientPrimeStatus(client);
}

void Settings(){
    char s_file[PLATFORM_MAX_PATH], s_plugin_name[128];
    if (!GetPluginInfo(INVALID_HANDLE, PlInfo_Name, s_plugin_name, sizeof(s_plugin_name))) GetPluginFilename(INVALID_HANDLE, s_plugin_name, sizeof(s_plugin_name));
    BuildPath( Path_SM, s_file, sizeof( s_file ), "configs/discord_settings.cfg" );
    KeyValues kv_data = CreateKeyValues( "Discord" );
    FileToKeyValues( kv_data, s_file );
    if (KvJumpToKey(kv_data, s_plugin_name))
    {
        KvGetString(kv_data, "webhook_url", s_webhook_URL, sizeof(s_webhook_URL), "https://discord.com/api/webhooks/xxxxx/xxxxxxx");
        KvGetString(kv_data, "prime.napas.cc_api", s_prime_api_key, sizeof(s_prime_api_key), "XXXXX-XXXXX-XXXXX-XXXXX");
        KvGetString(kv_data, "tag", s_tag_plugin, sizeof(s_tag_plugin), "[DROP]");
        f_wait_timer = KvGetFloat(kv_data, "timer", 182.0);
        i_play_sound_status = KvGetNum(kv_data, "sound_type", 1);
        b_chat_info = (KvGetNum(kv_data, "chat_info") ? true : false);
    }else{
        KvJumpToKey( kv_data, s_plugin_name, true );
        KvSetString(kv_data, "webhook_url", "https://discord.com/api/webhooks/xxxxx/xxxxxxx");
        KvSetString(kv_data, "prime.napas.cc_api", "XXXXX-XXXXX-XXXXX-XXXXX");
        KvSetString(kv_data, "tag", "[DROP]");
        KvSetFloat(kv_data, "timer", 182.0);
        KvSetNum(kv_data, "sound_type", 1);
        KvSetNum(kv_data, "chat_info", 1);
        KvRewind( kv_data );
        KeyValuesToFile( kv_data, s_file );
        strcopy(s_webhook_URL, sizeof(s_webhook_URL), "https://discord.com/api/webhooks/xxxxx/xxxxxxx");
        strcopy(s_prime_api_key, sizeof(s_prime_api_key), "XXXXX-XXXXX-XXXXX-XXXXX");
        strcopy(s_tag_plugin, sizeof(s_tag_plugin), "[DROP]");
        f_wait_timer = 182.0;
        i_play_sound_status = 1;
        b_chat_info = true;
    }
    delete kv_data;
}

MRESReturn Detour_RecordPlayerItemDrop(DHookParam hParams)
{
	if(h_wait_timer) delete h_wait_timer;
	int i_account_ID = hParams.GetObjectVar(1, 16, ObjectValueType_Int);
	int i_client = GetClientFromAccountID(i_account_ID);
	if(i_client != -1 && b_client_prime_status[ i_client ])
	{	
        ArrayList DataArray = new ArrayList(ByteCountToCells(1024));
        DataArray.Push(i_client);
        DataArray.Push(hParams.GetObjectVar(1, 20, ObjectValueType_Int));
        DataArray.Push(hParams.GetObjectVar(1, 24, ObjectValueType_Int));
        DataArray.Push(hParams.GetObjectVar(1, 28, ObjectValueType_Int));
        DataArray.Push(hParams.GetObjectVar(1, 32, ObjectValueType_Int));
        DropEvent(DataArray);
	}
	return MRES_Ignored;
}

void DropEvent(ArrayList DataArray){
    if(IsValidClient(DataArray.Get(0)))
    {
        char s_def_index[8];
        KeyValues kv = CreateKeyValues( "DropItems" );
        FileToKeyValues( kv, s_drop_items );
        KvRewind(kv);
        IntToString(DataArray.Get(1), s_def_index, sizeof(s_def_index));
        if (!KvJumpToKey(kv, s_def_index))
        {
            ItemQuery(DataArray);
        }else{
            char s_item_name[64], s_url[255];
            KvGetString(kv, "item_name", s_item_name, sizeof(s_item_name));
            KvGetString(kv, "item_image", s_url, sizeof(s_url));
            DataArray.PushString(s_item_name);
            DataArray.PushString(s_url);
            KvGetString(kv, "market_url", s_url, sizeof(s_url));
            DataArray.PushString(s_url);
            DropPriceHTTP(s_url, DataArray);
        }
        delete kv;
    }
}

void DropPriceHTTP(char url[255], ArrayList DataArray){
    Handle h_request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url);
    SteamWorks_SetHTTPRequestNetworkActivityTimeout(h_request, 10);
    SteamWorks_SetHTTPCallbacks(h_request, DropPrice);
    SteamWorks_SetHTTPRequestContextValue(h_request, DataArray);
    SteamWorks_SendHTTPRequest(h_request);
}

void DropPrice(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, ArrayList DataArray) 
{
    char s_item_price[16];
    if (!bRequestSuccessful || eStatusCode != k_EHTTPStatusCode200OK) 
    {
        delete hRequest;
        LogError("%t", "Failed to Drop Price", s_tag_plugin, DataArray.Get(1));
    }else{
        int i_response_size;
        SteamWorks_GetHTTPResponseBodySize(hRequest, i_response_size);
        char[] s_response = new char[i_response_size];
        SteamWorks_GetHTTPResponseBodyData(hRequest, s_response, i_response_size);
        delete hRequest;
        JSON_Object obj = json_decode(s_response);
        obj.GetString("median_price", s_item_price, sizeof(s_item_price));
        obj.Cleanup();
        delete obj;
    }
    DataArray.PushString(s_item_price);
    SendDropData(DataArray);
}

void SendDropData(ArrayList DataArray){
    if(IsValidClient(DataArray.Get(0))){
        Protobuf p_send_player_item_found = view_as<Protobuf>(StartMessageAll("SendPlayerItemFound", USERMSG_RELIABLE));
        p_send_player_item_found.SetInt("entindex", DataArray.Get(0));
        Protobuf hIteminfo = p_send_player_item_found.ReadMessage("iteminfo");
        hIteminfo.SetInt("defindex", DataArray.Get(1));
        hIteminfo.SetInt("paintindex", DataArray.Get(2));
        hIteminfo.SetInt("rarity", DataArray.Get(3));
        hIteminfo.SetInt("quality", DataArray.Get(4));
        hIteminfo.SetInt("inventory", 6); 
        EndMessage();
        SetHudTextParams(-1.0, 0.4, 3.0, GetRandomInt(0,255), GetRandomInt(0,255), GetRandomInt(0,255), 255);
        ShowHudText(DataArray.Get(0), -1, "%t", "Drop ShowHudText", s_tag_plugin);
        if(i_play_sound_status == 2) EmitSoundToAll("ui/panorama/case_awarded_1_uncommon_01.wav", SOUND_FROM_LOCAL_PLAYER, _, SNDLEVEL_NONE);
        else if(i_play_sound_status== 1) EmitSoundToClient(DataArray.Get(0), "ui/panorama/case_awarded_1_uncommon_01.wav", SOUND_FROM_LOCAL_PLAYER, _, SNDLEVEL_NONE);
        int i_array_size = GetArraySize(DataArray);
        char s_item_name[255], s_price[16];
        if(i_array_size >= 6 ) DataArray.GetString(5, s_item_name, sizeof(s_item_name));
        else Format(s_item_name,sizeof(s_item_name), "%t", "Unknow Drop");
        if(i_array_size >= 9 ) DataArray.GetString(8, s_price, sizeof(s_price));
        else Format(s_price,sizeof(s_price), "%t", "Unknow Price");
        LogToFile(s_log_file, "%t", "Drop Log",  DataArray.Get(0), DataArray.Get(1), DataArray.Get(2), DataArray.Get(3), DataArray.Get(4), s_item_name, s_price);
        CPrintToChatAll("%t", "Drop Log Chat",s_tag_plugin, DataArray.Get(0), s_item_name, s_price);
        if(!StrEqual(s_webhook_URL, "https://discord.com/api/webhooks/xxxxx/xxxxxxx")){
            char s_item_url[1024], s_image[255], s_hex_char[]="0123456789ABCDEF\0", s_color[8], s_temp[255], s_temp2[255]; 
            Format(s_color, sizeof(s_color), "#%c%c%c%c%c%c",s_hex_char[GetRandomInt(0,15)],s_hex_char[GetRandomInt(0,15)],s_hex_char[GetRandomInt(0,15)],s_hex_char[GetRandomInt(0,15)],s_hex_char[GetRandomInt(0,15)],s_hex_char[GetRandomInt(0,15)]);
            if(i_array_size >= 8 ){
                DataArray.GetString(7, s_item_url, sizeof(s_item_url));
                ReplaceString(s_item_url, sizeof(s_item_url), "https://steamcommunity.com/market/priceoverview/?appid=730&currency=17&market_hash_name=", "https://steamcommunity.com/market/listings/730/");
            }else strcopy (s_item_url, sizeof(s_item_url), "https://steamcommunity.com/market/listings/730/");
            if(i_array_size >= 7 ) DataArray.GetString(6, s_image, sizeof(s_image));
            if(strlen(s_image) < 10) strcopy (s_image, sizeof(s_image), s_plugin_image);
            DiscordWebHook dw_hook = new DiscordWebHook(s_webhook_URL);
            dw_hook.SlackMode = true;
            MessageEmbed me_embed = new MessageEmbed();
            me_embed.SetColor(s_color);
            me_embed.SetThumb(s_image);
            Format(s_temp, sizeof(s_temp), "%t", "Embed SetTitle");
            if (s_temp[0] != '-') me_embed.SetTitle(s_temp);
            Format(s_temp, sizeof(s_temp), "%t", "Embed Field Hostname Title");
            if (s_temp[0] != '-'){
                char s_net_ip[ 16 ];
                GetConVarString(FindConVar("hostname"), s_temp2, sizeof(s_temp2));
                int i_longip = GetConVarInt(FindConVar("hostip")) , i_pieces[4];
                i_pieces[0] = (i_longip >> 24) & 0x000000FF;
                i_pieces[1] = (i_longip >> 16) & 0x000000FF;
                i_pieces[2] = (i_longip >> 8) & 0x000000FF;
                i_pieces[3] = i_longip & 0x000000FF;
                Format(s_net_ip, sizeof(s_net_ip), "%d.%d.%d.%d", i_pieces[0], i_pieces[1], i_pieces[2], i_pieces[3]);
                Format(s_temp2, sizeof(s_temp2), "%t", "Embed Field Hostname Content", s_temp2, s_net_ip, GetConVarInt(FindConVar("hostport")));
                me_embed.AddField(s_temp, s_temp2,false);
            }
            Format(s_temp, sizeof(s_temp), "%t", "Embed Field Player Info Title");
            if (s_temp[0] != '-'){
                char s_steam_id[32],  s_steam_id64[32], s_username[(MAX_NAME_LENGTH + 1) * 2];
                GetClientName(DataArray.Get(0), s_username, sizeof(s_username));
                GetClientAuthId(DataArray.Get(0), AuthId_Steam2, s_steam_id, sizeof(s_steam_id));
                GetClientAuthId(DataArray.Get(0), AuthId_SteamID64, s_steam_id64, sizeof(s_steam_id64));	
                Format(s_temp2, sizeof(s_temp2), "%t", "Embed Field Player Info Content", s_username, s_steam_id, s_steam_id64);
                me_embed.AddField(s_temp, s_temp2,false);
            }
            Format(s_temp, sizeof(s_temp), "%t", "Embed Field Item Info Title");
            if (s_temp[0] != '-'){
                Format(s_temp2, sizeof(s_temp2), "%t", "Embed Field Item Info Content", s_item_name);
                me_embed.AddField(s_temp, s_temp2,false);
            }
            Format(s_temp, sizeof(s_temp), "%t", "Embed Field Price Info Title");
            if (s_temp[0] != '-'){
                Format(s_temp2, sizeof(s_temp2), "%t", "Embed Field Price Info Content", s_price, s_item_url);
                me_embed.AddField(s_temp, s_temp2,false);
            }
            FormatTime(s_temp2, sizeof(s_temp2), "%d.%m.%Y %X", GetTime());
            Format(s_temp, sizeof(s_temp), "%t", "Embed Footer", s_tag_plugin, s_temp2);
            me_embed.SetFooterIcon(s_plugin_image);
            if (s_temp[0] != '-')me_embed.SetFooter(s_temp);
            dw_hook.Embed(me_embed);
            dw_hook.Send();
            delete dw_hook;
        }
    }
}

void ItemQuery(ArrayList DataArray){
    char s_url[255];
    Format(s_url,sizeof(s_url),"%s%d", API_URL, DataArray.Get(1));
    Handle h_request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, s_url);
    SteamWorks_SetHTTPRequestNetworkActivityTimeout(h_request, 10);
    SteamWorks_SetHTTPCallbacks(h_request, DropItem);
    SteamWorks_SetHTTPRequestContextValue(h_request, DataArray);
    SteamWorks_SendHTTPRequest(h_request);
}

void DropItem(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, ArrayList DataArray) 
{
    bool b_status = false;
    if (!bRequestSuccessful || eStatusCode != k_EHTTPStatusCode200OK) 
    {
        delete hRequest;
        LogError("%t", "Failed to Drop Item", s_tag_plugin, DataArray.Get(1));
    }else{
        int i_response_size;
        SteamWorks_GetHTTPResponseBodySize(hRequest, i_response_size);
        char[] s_response = new char[i_response_size];
        SteamWorks_GetHTTPResponseBodyData(hRequest, s_response, i_response_size);
        delete hRequest;
        KeyValues kv_data = CreateKeyValues("DropItem");
        if (kv_data.ImportFromString(s_response)){
            if (KvJumpToKey(kv_data, "result")){
                if(KvGetNum(kv_data, "success")==1){
                    char s_item_name[64], s_image_url[255], s_market_url[255];
                    KvGetString(kv_data, "item_name", s_item_name, sizeof(s_item_name) );
                    KvGetString(kv_data, "item_image", s_image_url, sizeof(s_image_url) );
                    KvGetString(kv_data, "market_url", s_market_url, sizeof(s_market_url) );
                    DataArray.PushString(s_item_name);
                    DataArray.PushString(s_image_url);
                    DataArray.PushString(s_market_url);
                    NewItem(DataArray.Get(1), s_item_name, s_image_url, s_market_url);
                    DropPriceHTTP(s_market_url, DataArray);
                    b_status = true;
                }else{
                    char s_error[255];
                    KvGetString(kv_data, "error", s_error, sizeof(s_error), "UNKNOW" );
                    LogError("%t", "Failed to Drop Item Status Error", s_tag_plugin, DataArray.Get(1), s_error);
                }
            }else LogError("%t", "Failed to Drop Item Result Error", s_tag_plugin, DataArray.Get(1));
        }else LogError("%t", "Failed to Drop Item ImportFromString", s_tag_plugin, DataArray.Get(1));
        delete kv_data;
    }
    if(!b_status)SendDropData(DataArray);
}

void NewItem(int def_index, char item_name[64], char image_url[255], char market_url[255]){
    char s_def_index[8];
    KeyValues kv_data = CreateKeyValues( "DropItems" );
    FileToKeyValues( kv_data, s_drop_items );
    IntToString(def_index, s_def_index, sizeof(s_def_index));
    if (KvJumpToKey(kv_data, s_def_index, true))
    {
        KvSetString(kv_data, "item_name", item_name);
        KvSetString(kv_data, "item_image", image_url);
        KvSetString(kv_data, "market_url", market_url);
        KvRewind(kv_data);
        KeyValuesToFile(kv_data, s_drop_items);
        PrintToServer("%t", "New Item", s_tag_plugin , def_index, item_name);
    }
    delete kv_data;
}

int GetClientFromAccountID(int accound_ID)
{
	for(int i = 1; i <= MaxClients; i++)if(IsValidClient(i) && IsClientAuthorized(i))if(GetSteamAccountID(i) == accound_ID)return i;
	return -1;
}

Action TryDropping(Handle hTimer)
{
	if(b_chat_info)
	{
		h_wait_timer = CreateTimer(1.2, DropFailed);
		CPrintToChatAll("%t", "Trying Drop", s_tag_plugin);
	}
	if(i_OS == 1)SDKCall(h_match_end_drops, 0xDEADC0DE, false);
	else SDKCall(h_match_end_drops, false);
	return Plugin_Continue;
}

Action DropFailed(Handle hTimer)
{
    h_wait_timer = null;
    CPrintToChatAll("%t", "Drop Attempt Failed", s_tag_plugin);
}

void ClientPrimeStatus(int client){
    b_client_prime_status[ client ] = false;
    if (IsValidClient(client)){
        if (SteamWorks_HasLicenseForApp(client, 624820) == k_EUserHasLicenseResultHasLicense){
            b_client_prime_status[ client ] = true;
            PrintToServer("%t", "Client Prime", s_tag_plugin, client);
        }else
        {
            char s_account_id[24];
            Handle h_request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, "https://prime.napas.cc/request");
            SteamWorks_SetHTTPRequestNetworkActivityTimeout(h_request, 10);
            IntToString(GetSteamAccountID(client), s_account_id, sizeof(s_account_id));
            SteamWorks_SetHTTPRequestGetOrPostParameter(h_request, "key", 		s_prime_api_key);
            SteamWorks_SetHTTPRequestGetOrPostParameter(h_request, "accountid", s_account_id);
            SteamWorks_SetHTTPCallbacks(h_request, HTTPRequestComplete);
            SteamWorks_SetHTTPRequestContextValue(h_request, client);
            SteamWorks_SendHTTPRequest(h_request);
        }
    }
}

void HTTPRequestComplete(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, int client){
	delete hRequest;
	if(IsValidClient(client)){
		if(bFailure){
                PrintToServer("%t", "Failed to Prime Control", s_tag_plugin, client);
                CreateTimer(15.0, TIMER_DELAY, client, TIMER_FLAG_NO_MAPCHANGE);
		}else{
            switch(eStatusCode){
			case k_EHTTPStatusCode200OK:{
                b_client_prime_status[client] = true;
                PrintToServer("%t", "Client Prime", s_tag_plugin, client);
            }
            case k_EHTTPStatusCode204NoContent:{
                b_client_prime_status[client] = false;
                PrintToServer("%t", "Client NoPrime", s_tag_plugin, client);
            }
			case k_EHTTPStatusCode400BadRequest:{
                PrintToServer("%t", "Prime Api Invalid Request", s_tag_plugin, client);
			}
			case k_EHTTPStatusCode403Forbidden:{
				PrintToServer("%t", "Prime Api Invalid Api Key", s_tag_plugin, client);
			}
			case k_EHTTPStatusCode503ServiceUnavailable:{
                PrintToServer("%t", "Prime Api Try", s_tag_plugin, client);
                CreateTimer(15.0, TIMER_DELAY, client, TIMER_FLAG_NO_MAPCHANGE);
			}
		}
        }
		
	}
}

Action TIMER_DELAY(Handle hTimer, int client){
	if(IsValidClient(client))ClientPrimeStatus(client);
}