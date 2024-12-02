#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>
#include <tf2_stocks>
#include <tf2utils>

#include <tf_econ_dynamic>
#include <tf2attributes>

#include <stocksoup/memory>

#pragma newdecls required
#pragma semicolon 1

#define MASK_BUILDINGS MASK_PLAYERSOLID_BRUSHONLY

enum {
	BUILDING_INVALID_OBJECT = ((1<<8)-1), // s8_t:-1
	BUILDING_DISPENSER = 0,
	BUILDING_TELEPORTER,
	BUILDING_SENTRYGUN,
	BUILDING_ATTACHMENT_SAPPER
};

enum {
	BS_IDLE,
	BS_SELECTING,
	BS_PLACING,
	BS_PLACING_INVALID,
};

enum eTossBuildingState {
	eTossBuilding_Invalid = -1,
	eTossBuilding_OK = 0,
	eTossBuilding_NotAllowed = 1
};

enum struct AirbornObjectHook {
	int ref;
	int ResolveCollsionHook;
	int SolidMaskHook;
}

//ArrayList g_aAirbornObject;

Handle SDKCall_BuilderStartBuilding;
DynamicHook DHook_OnResolveFlyCollisionCustom;
DynamicHook DHook_PhysicsSolidMaskForEntity;
DynamicHook DHook_ObjectOnGoActive;

bool g_bPlayerThrow[MAXPLAYERS+1];
float g_flClientLastBeep[MAXPLAYERS+1];
float g_flClientLastNotif[MAXPLAYERS+1]; //for hud notifs, as those make noise

#define TBLOCK_WFP (1 << 0)
int g_iBlockFlags;

public Plugin myinfo = {
	name = "[TF2] Toss Building Rewrite",
	description = "Use your reload button to toss carried buildings",
	author = "",
	version = "",
	url = "N/A",
};

/**
 * Main Starts.
 */

public void OnPluginStart() {
	GameData gameConf = new GameData("tbobj.games");
	if (gameConf == null)
		SetFailState("Could not load gamedata: File is missing");
	
	StartPrepSDKCall(SDKCall_Entity); //weapon
	PrepSDKCall_SetFromConf(gameConf, SDKConf_Signature, "CTFWeaponBuilder::StartBuilding()");
	SDKCall_BuilderStartBuilding = EndPrepSDKCall();
	if (!SDKCall_BuilderStartBuilding) {
		SetFailState("Could not load gamedata: CTFWeaponBuilder::StartBuilding() Signature missing or outdated");
	}
	
	DHook_OnResolveFlyCollisionCustom = DynamicHook.FromConf(gameConf, "CBaseEntity::ResolveFlyCollisionCustom()");
	DHook_PhysicsSolidMaskForEntity = DynamicHook.FromConf(gameConf, "CBaseEntity::PhysicsSolidMaskForEntity()");
	DHook_ObjectOnGoActive = DynamicHook.FromConf(gameConf, "CBaseObject::OnGoActive()");
	
	delete gameConf;
	
	TF2EconDynAttribute attrib = new TF2EconDynAttribute();
	attrib.SetCustom("hidden", "1");
	
	attrib.SetName("toss building force");
	attrib.SetClass("toss_building_force");
	attrib.SetDescriptionFormat("value_is_percentage");
	attrib.Register();
	
	attrib.SetName("toss building gravity");
	attrib.SetClass("toss_building_gravity");
	attrib.SetDescriptionFormat("value_is_percentage");
	attrib.Register();
	
	attrib.SetName("can toss building");
	attrib.SetClass("can_toss_building");
	attrib.SetCustom("stored_as_integer", "1");
	attrib.SetDescriptionFormat("value_is_additive");
	attrib.Register();

	attrib.SetName("toss building ammo");
	attrib.SetClass("toss_building_ammo");
	attrib.SetCustom("stored_as_integer", "1");
	attrib.SetDescriptionFormat("value_is_additive");
	attrib.Register();
	
	delete attrib;
	
	//g_aAirbornObject = new ArrayList(sizeof(AirbornObjectHook)); //ref, collsion hook, solidmask hook.
	
	HookEvent("player_carryobject", OnPlayerCarryObject);
	HookEvent("player_builtobject", OnPlayerBuiltObject);
	HookEvent("player_dropobject", OnPlayerBuiltObject);
}

/*
public void OnMapStart() {
	g_aAirbornObject.Clear();
}
*/

public void OnClientDisconnect(int client) {
	g_bPlayerThrow[client] = false;
	g_flClientLastBeep[client] = 0.0;
	g_flClientLastNotif[client] = 0.0;
}

public void TF2_OnWaitingForPlayersStart() {
	g_iBlockFlags |= TBLOCK_WFP;
}

public void TF2_OnWaitingForPlayersEnd() {
	g_iBlockFlags &=~ TBLOCK_WFP;
}


public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2]) {
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client)) {
		return Plugin_Continue;
	}
	
	static bool holding[MAXPLAYERS + 1];
	if (buttons & IN_RELOAD) {
		if (!holding[client]) {
			if (!g_bPlayerThrow[client]) {
				eTossBuildingState state = IsThrowAllowed(client);
				switch (state) {
					case eTossBuilding_NotAllowed: {
						if (GetClientTime(client) - g_flClientLastNotif[client] >= 1.0) {
							g_flClientLastNotif[client] = GetClientTime(client);
							HudNotify(client, "You can't toss this building");
						}
					}
					case eTossBuilding_OK: {
						g_bPlayerThrow[client] = true;
						if (CheckThrowPos(client)) StartBuilding(client);
						g_bPlayerThrow[client] = false;
					}
				}
			}
			holding[client] = true;
		}
	} else {
		if (holding[client])
			holding[client] = false;
	}
	return Plugin_Continue;
}

/**
 * Events Start.
 */

public void OnPlayerCarryObject(Event event, const char[] name, bool dontBroadcast) {
	int owner = GetClientOfUserId(event.GetInt("userid"));
	int type = event.GetInt("object");
	int building = event.GetInt("index");
	if ((BUILDING_DISPENSER <= type <= BUILDING_SENTRYGUN) && IsClientInGame(owner) && IsValidEdict(building) && IsThrowAllowed(owner, type) == eTossBuilding_OK) {
		HudNotify(owner, "Press [RELOAD] to toss the building");
	}
}

public void OnPlayerBuiltObject(Event event, const char[] name, bool dontBroadcast) {
	int owner = GetClientOfUserId(event.GetInt("userid"));
	int objecttype = event.GetInt("object");
	int building = event.GetInt("index");
	
	if ((BUILDING_DISPENSER <= objecttype <= BUILDING_SENTRYGUN) && IsClientInGame(owner) && IsValidEdict(building) && g_bPlayerThrow[owner]) {
		g_bPlayerThrow[owner] = false;
		SetEntityCollisionGroup(building, 2);

		DHook_OnResolveFlyCollisionCustom.HookEntity(Hook_Post, building, OnResolveFlyCollisionPost);
		DHook_PhysicsSolidMaskForEntity.HookEntity(Hook_Post, building, PhysicsSolidMaskForEntityPost);

		if (BUILDING_SENTRYGUN == objecttype) {
			DHook_ObjectOnGoActive.HookEntity(Hook_Post, building, ObjectOnGoActivePost);
		}
		
		/*
		if (g_aAirbornObject.FindValue(buildref, AirbornObjectHook::ref) == -1) {
			AirbornObjectHook objectHook;
			objectHook.ref = buildref;
			objectHook.ResolveCollsionHook = DHook_OnResolveFlyCollisionCustom.HookEntity(Hook_Post, building, OnResolveFlyCollisionPost);
			objectHook.SolidMaskHook = DHook_PhysicsSolidMaskForEntity.HookEntity(Hook_Post, building, PhysicsSolidMaskForEntityPost);
			
			g_aAirbornObject.PushArray(objectHook);
		}
		*/
		
		int buildref = EntIndexToEntRef(building);
		RequestFrame(ThrowBuilding, buildref);
	}
}

public void ThrowBuilding(int buildref) {
	int building = EntRefToEntIndex(buildref);
	if (building == INVALID_ENT_REFERENCE)
		return;
	
	int owner = GetEntPropEnt(building, Prop_Send, "m_hBuilder");
	if (owner < 1 || owner > MaxClients || !IsClientInGame(owner)) {
		//RemoveFromAirbornArray(buildref);
		return;
	}
	
	static float eyes[3], origin[3], angles[3], fwd[3], velocity[3];
	GetClientEyePosition(owner, origin);
	eyes = origin;
	
	//set origin in front of player
	GetClientEyeAngles(owner, angles);
	angles[0] = 0.0;
	GetAngleVectors(angles, fwd, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(fwd, 64.0);
	AddVectors(origin, fwd, origin);
	
	float throwForce = TF2Attrib_HookValueFloat(300.0, "toss_building_force", owner);
	float gravity = TF2Attrib_HookValueFloat(1.0, "toss_building_gravity", owner);
	
	//get angles/velocity
	GetClientEyeAngles(owner, angles);
	GetAngleVectors(angles, fwd, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(fwd, throwForce);
	fwd[2] += throwForce;
	
	GetEntPropVector(owner, Prop_Data, "m_vecAbsVelocity", velocity);
	AddVectors(velocity, fwd, velocity);
	angles[0] = angles[2] = 0.0; //upright angle = 0.0 yaw 0.0
	
	//double up the CheckThrowPos trace, since we're a tick later
	TR_TraceRayFilter(eyes, origin, MASK_PLAYERSOLID, RayType_EndPoint, TraceFilter_PassSelfAndClients, owner);
	if (TR_DidHit()) {
		// the building is already going up, we need to either handle the refund or break the building
		BreakBuilding(building);
		return;
	}

	// SetEntProp(building, Prop_Send, "m_usSolidFlags", view_as<SolidFlags_t>(GetEntProp(building, Prop_Data, "m_usSolidFlags")) | FSOLID_NOT_SOLID);
	VS_SetMoveType(building, 5, 2);
	SetEntityGravity(building, gravity);
	TeleportEntity(building, origin, angles, velocity);
	RequestFrame(NextFrame_HookGroundEntChange, buildref);
}

public void NextFrame_HookGroundEntChange(int buildref) {
	int building = EntRefToEntIndex(buildref);
	if (building == INVALID_ENT_REFERENCE)
		return;

	SDKHook(building, SDKHook_GroundEntChangedPost, OnBuildingGroundEntChanged);
}

static bool bTEEFuncNobuildFound;
//return true to continue search
public bool TEE_SearchFuncNobuild(int entity, any data) {
	char classname[32];
	if (entity == data) return true;
	GetEntityClassname(entity, classname, sizeof(classname));
	// TF2Util_IsPointInRespawnRoom is only checking for same team spawn room - daheck?
	if (StrEqual(classname, "func_nobuild") || StrEqual(classname, "func_respawnroom")) {
		bTEEFuncNobuildFound = true;
		return false;
	}
	return true;
}

MRESReturn OnResolveFlyCollisionPost(int building, DHookParam params) {
	Address paramAddress = params.GetAddress(1);
	float zValue = view_as<float>(LoadFromAddress(paramAddress + view_as<Address>(32), NumberType_Int32));
	//PrintToChatAll("%f", zValue);
	
	bool invalid = zValue <= 0.7;
	
	if (invalid) {
		RequestFrame(NextFrame_BreakBuilding, EntIndexToEntRef(building));
	}
	
	return MRES_Ignored;
}

MRESReturn PhysicsSolidMaskForEntityPost(int entity, DHookReturn ret) {
	ret.Value = ret.Value | CONTENTS_PLAYERCLIP;
	return MRES_Override;
}

MRESReturn ObjectOnGoActivePost(int building) {
	int owner = GetEntPropEnt(building, Prop_Send, "m_hBuilder");
	int iAmmo = TF2Attrib_HookValueInt(0, "toss_building_ammo", owner);
	int curAmmo = GetEntProp(building, Prop_Send, "m_iAmmoShells");

	if(curAmmo > iAmmo) {
		SetEntProp(building, Prop_Send, "m_iAmmoShells", iAmmo);
	}
	
	return MRES_Ignored;
}

public void OnBuildingGroundEntChanged(int building) {
	float origin[3], maxs[3], mins[3];
	GetEntPropVector(building, Prop_Send, "m_vecOrigin", origin);
	GetEntPropVector(building, Prop_Send, "m_vecMins", mins);
	GetEntPropVector(building, Prop_Send, "m_vecMaxs", maxs);
	AddVectors(mins, {4.0, 4.0, 4.0}, mins);
	SubtractVectors(maxs, {4.0, 4.0, 4.0}, maxs);
	
	TR_TraceHullFilter(origin, origin, mins, maxs, MASK_BUILDINGS, TraceFilter_PassSelf, building);
	bool invalid = TR_DidHit() || TF2Util_IsPointInRespawnRoom(origin, building);
	if (!invalid) {
		//look for nobuild areas
		bTEEFuncNobuildFound = false;
		TR_EnumerateEntitiesHull(origin, origin, mins, maxs, PARTITION_TRIGGER_EDICTS, TEE_SearchFuncNobuild, building);
		if (bTEEFuncNobuildFound) {
			invalid = true;
		}
	}
	
	if (invalid) {
		BreakBuilding(building);
		return;
	} else {
		// SetEntProp(building, Prop_Data, "m_usSolidFlags", view_as<SolidFlags_t>(GetEntProp(building, Prop_Data, "m_usSolidFlags")) & ~FSOLID_NOT_SOLID);	
		TeleportEntity(building, _, _, {0.0, 0.0, 0.0});
		SetEntityCollisionGroup(building, GetEntProp(building, Prop_Send, "m_iObjectType") == BUILDING_TELEPORTER ? 22 : 21);
		VS_SetMoveType(building, 0, 0);
	}
	
	//RemoveFromAirbornArray(EntIndexToEntRef(building));
	SDKUnhook(building, SDKHook_GroundEntChangedPost, OnBuildingGroundEntChanged);
}

bool CheckThrowPos(int client) {
	if (g_iBlockFlags != 0) 
		return false;
	
	float eyes[3], origin[3], angles[3], fwd[3];
	GetClientEyePosition(client, origin);
	eyes = origin;
	
	//set origin in front of player
	GetClientEyeAngles(client, angles);
	angles[0] = 0.0;
	GetAngleVectors(angles, fwd, NULL_VECTOR, NULL_VECTOR);
	NormalizeVector(fwd, fwd);
	ScaleVector(fwd, 80.0);
	AddVectors(origin, fwd, origin);
	
	//ensure we see the target
	TR_TraceRayFilter(eyes, origin, MASK_PLAYERSOLID, RayType_EndPoint, TraceFilter_PassSelfAndClients, client);
	bool hit = TR_DidHit();
	
	//can't see throw point (prevent through walls)? make noise
	if (hit) Beep(client);
	return !hit;
}

int StartBuilding(int client) {
	if (!IsClientInGame(client) || !IsPlayerAlive(client))
		return -1;
	
	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	int item = IsValidEntity(weapon) ? GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex") : -1;
	if (item != 28)
		return -1; //require builder
	
	int bstate = GetEntProp(weapon, Prop_Send, "m_iBuildState");
	if (bstate != BS_PLACING && bstate != BS_PLACING_INVALID)
		return -1; //currently not placing
	
	int objectToBuild = GetEntPropEnt(weapon, Prop_Send, "m_hObjectBeingBuilt");
	
	if (objectToBuild == INVALID_ENT_REFERENCE) {
		RequestFrame(NextFrame_FixNoObjectBeingHeld, GetClientUserId(client));
		return -1; //no object being build!?
	}
	
	int type = GetEntProp(objectToBuild, Prop_Send, "m_iObjectType");
	if (type < BUILDING_DISPENSER || type > BUILDING_SENTRYGUN)
		return -1; //supported buildings, not always correct on weapon_builder
	
	SetEntPropEnt(weapon, Prop_Send, "m_hOwner", client);
	SetEntProp(weapon, Prop_Send, "m_iBuildState", BS_PLACING); //if placing_invalid
	SDKCall(SDKCall_BuilderStartBuilding, weapon);
	
	return objectToBuild;
}

void NextFrame_FixNoObjectBeingHeld(int userid) {
	//go through all validation again
	int client = GetClientOfUserId(userid);
	if (!client || !IsClientInGame(client) || !IsPlayerAlive(client))
		return;
	
	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	int item = IsValidEntity(weapon) ? GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex") : -1;
	
	if (item != 28)
		return; //weapon switched
	
	int type = GetEntProp(weapon, Prop_Send, "m_iObjectType");
	if (!(BUILDING_DISPENSER <= type <= BUILDING_SENTRYGUN))
		return; //unsupported building
	
	int bstate = GetEntProp(weapon, Prop_Send, "m_iBuildState");
	if (bstate != BS_PLACING && bstate != BS_PLACING_INVALID)
		return; //not in a glitched state
	
	int objectToBuild = GetEntPropEnt(weapon, Prop_Send, "m_hObjectBeingBuilt");
	
	if (objectToBuild == INVALID_ENT_REFERENCE) {
		//holding empty box, try to find another weapon to switch to
		for (int i = 2; i >= 0; i--) {
			weapon = GetPlayerWeaponSlot(client, i);
			if (weapon != -1) {
				if (TF2Util_SetPlayerActiveWeapon(client, weapon)) {
					break;
				}
			}
		}
	}
}

eTossBuildingState IsThrowAllowed(int client, int type = BUILDING_INVALID_OBJECT) {
	if (!IsClientInGame(client) || !IsPlayerAlive(client))
		return eTossBuilding_Invalid;
	
	int objectType = type;
	if (objectType == BUILDING_INVALID_OBJECT) {
		int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
		int item = IsValidEntity(weapon) ? GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex") : -1;
		
		if (item != 28)
			return eTossBuilding_Invalid; //require builder
		
		int bstate = GetEntProp(weapon, Prop_Send, "m_iBuildState");
		if (bstate != BS_PLACING && bstate != BS_PLACING_INVALID)
			return eTossBuilding_Invalid; //currently not placing
		
		int objectToBuild = GetEntPropEnt(weapon, Prop_Send, "m_hObjectBeingBuilt");
		
		if (objectToBuild == INVALID_ENT_REFERENCE) {
			RequestFrame(NextFrame_FixNoObjectBeingHeld, GetClientUserId(client));
			return eTossBuilding_Invalid; //no object being built!?
		}
		
		objectType = GetEntProp(objectToBuild, Prop_Send, "m_iObjectType");
	}
	
	if (!(BUILDING_DISPENSER <= objectType <= BUILDING_SENTRYGUN))
		return eTossBuilding_Invalid; //supported buildings, not always correct on weapon_builder
	
	int allowed = TF2Attrib_HookValueInt(0, "can_toss_building", client);
	return (allowed & (1 << objectType)) ? eTossBuilding_OK : eTossBuilding_NotAllowed;
}

public bool TraceFilter_Thrown(int entity, int contentsMask, any data) {
	if (!entity) 
		return contentsMask != CONTENTS_EMPTY;
	
	return entity > MaxClients;
}

public bool TraceFilter_PassSelf(int entity, int contentsMask, any data) {
	return entity != data;
}

public bool TraceFilter_PassSelfAndClients(int entity, int contentsMask, any data) {
	return entity > MaxClients && entity != data;
}

public bool TraceFilter_OnlyClients(int entity, int contentsMask, any data) {
	return 0 < entity <= MaxClients;
}

stock void VS_SetMoveType(int entity, int moveType, int moveCollide) {
	char buffer[128]; Format(buffer, sizeof(buffer), "!self.SetMoveType(%d, %d)", moveType, moveCollide);
	
	SetVariantString(buffer);
	AcceptEntityInput(entity, "RunScriptCode");
}

/*
void RemoveFromAirbornArray(int buildref) {
	int index = g_aAirbornObject.FindValue(buildref, AirbornObjectHook::ref);
	if (index != -1) {
		AirbornObjectHook objectHook;
		g_aAirbornObject.GetArray(index, objectHook);
		DynamicHook.RemoveHook(objectHook.ResolveCollsionHook);
		DynamicHook.RemoveHook(objectHook.SolidMaskHook);
		g_aAirbornObject.Erase(index);
	}
}
*/

void BreakBuilding(int building) {
	//RemoveFromAirbornArray(EntIndexToEntRef(building));
	
	SetVariantInt(RoundToCeil(GetEntProp(building, Prop_Data, "m_iHealth") * 1.5));
	AcceptEntityInput(building, "RemoveHealth");
}

void NextFrame_BreakBuilding(int ref) {
	int building = EntRefToEntIndex(ref);
	if (building != INVALID_ENT_REFERENCE) {
		BreakBuilding(building);
	}
}

void Beep(int client) {
	if (!(1<=client<=MaxClients) || !IsClientInGame(client) || IsFakeClient(client)) return;
	if (GetClientTime(client) - g_flClientLastBeep[client] >= 1.0) {
		g_flClientLastBeep[client] = GetClientTime(client);
		EmitSoundToClient(client, "common/wpn_denyselect.wav");//should aready be precached by game
	}
}

void HudNotify(int client, const char[] format, any ...) {
	char buffer[128];
	VFormat(buffer, sizeof(buffer), format, 3);
	PrintHintText(client, "%s", buffer);
}