// Model the engine boundary: SELL detaches immediately, BUY can be refused.
// Both native request code paths are compiled from the production source.
namespace request_test {
enum class Reason { Ok, Engine, Offline, NotAllowed, Moved, Missing };
struct Fvector {};
struct CSE_Abstract { virtual ~CSE_Abstract()=default; u16 ID_Parent=1; };
struct CSE_ALifeDynamicObject : CSE_Abstract {
    bool m_bOnline=true; int m_tGraphID=0; Fvector o_Position; std::vector<u16> children;
};
struct CSE_ALifeInventoryItem : CSE_ALifeDynamicObject {};
struct NET_Packet;
struct CGameObject {
    virtual ~CGameObject()=default;
    u16 id=0; CGameObject* parent=nullptr; bool destroying=false;
    CGameObject* H_Parent(){return parent;} u16 ID()const{return id;}
    static void u_EventGen(NET_Packet&,int,u16){} static void u_EventSend(NET_Packet&){}
};
struct CInventoryItem : CGameObject { bool takeable=true; };
struct Inventory { bool full=false; bool CanTakeItem(CInventoryItem* i){return i->takeable&&!full;} };
struct CInventoryOwner : CGameObject { Inventory bag; Inventory& inventory(){return bag;} };
CInventoryOwner sender, receiver;
CInventoryItem item;
CSE_ALifeInventoryItem entity;
bool reject_take=false;
int sent_events=0;
CGameObject* valid_go(u16 id) {
    CGameObject* o=id==1?static_cast<CGameObject*>(&sender):id==2?static_cast<CGameObject*>(&receiver):id==3?&item:nullptr;
    return o&&!o->destroying?o:nullptr;
}
bool entity_gone=false; // the item's server object is gone (a release of this frame)
namespace events {
CSE_Abstract* find_entity(u16 id){return id==3&&!entity_gone?&entity:nullptr;}
void host_set_drop_position(u16,const Fvector&){}
void host_on_parent_changed(u16,u16,u16){}
}
constexpr int GE_TRADE_SELL=1, GE_OWNERSHIP_REJECT=2, GE_TRADE_BUY=3, GE_OWNERSHIP_TAKE=4, GE_CHANGE_POS=5;
void inject_item_event(int kind,u16 holder,u16 id) {
    require(id==3,"must preserve the same entity");++sent_events;
    if(kind==GE_TRADE_SELL||kind==GE_OWNERSHIP_REJECT) {
        if(entity.ID_Parent==holder)entity.ID_Parent=kNoId;
    } else if(entity.ID_Parent==kNoId && !(reject_take&&holder==2)) entity.ID_Parent=holder;
}
struct NET_Packet { void w_vec3(const Fvector&){} };
struct Objects { CSE_ALifeDynamicObject* object(u16 id,bool){return id==3?&entity:nullptr;} };
struct Graph { void detach(CSE_ALifeDynamicObject&,CSE_ALifeInventoryItem*,int,bool,bool){} void attach(CSE_ALifeDynamicObject&,CSE_ALifeInventoryItem*,int,bool,bool){} };
struct Alife { Objects objects(){return {};} Graph graph(){return {};} };
struct AI { Alife alife(){return {};} };
AI ai(){return {};} Alife alife_rw(){return {};}
bool authority=true;
bool is_map_authority(){return authority;}
const char* reason_name(Reason){return "test";}
// host_transfer_item's own helpers (engine: Level().Objects, the item's section): the slice records what it was told.
bool item_dying(u16 id){return id==3&&item.destroying;}
struct ScriptMoveCounters{u64 refused=0,already=0,dying=0,in_place=0;} g_script_moves;
std::vector<Reason> logged;
void log_script_move_refused(u16,u16,u16,Reason why,const xr_string&){logged.push_back(why);}
#include "request_move.inc"
void run(const std::string& mode) {
    sender.id=1;receiver.id=2;item.id=3;item.parent=&sender;
    // Reports #705/#708 and GAMMA's npc:transfer_item(item, npc) (keep_guns_on_bodies, the wounded animation fix): a move to the
    // holder the item has is the stock pair's (SELL + BUY puts a slotted item into the ruck): false lets it run here.
    if(mode=="gift-host-script-self") {
        bool handled=host_transfer_item(3,1,1);
        require(!handled,"a move to the holder it has must fall through to the stock SELL + BUY pair");
        require(sent_events==0 && entity.ID_Parent==1,"the slice must not move the item itself: the stock pair does");
        require(g_script_moves.in_place==1 && logged.empty(),"a move in place is counted, never logged");
        return;
    }
    if(mode=="gift-host-script-self-moved") {
        bool handled=host_transfer_item(3,2,2);
        require(handled,"a move in place of an item another holder has is refused here, not run as stock");
        require(sent_events==0 && entity.ID_Parent==1,"a refused move in place changes nothing");
        require(logged.size()==1 && logged[0]==Reason::Moved && g_script_moves.refused==1,"it is logged as moved, with its data");
        return;
    }
    if(mode=="gift-host-script-already") {
        entity.ID_Parent=2;item.parent=&receiver;
        bool handled=host_transfer_item(3,1,2);
        require(handled,"a move that is done already is handled");
        require(sent_events==0 && entity.ID_Parent==2,"a move that is done already changes nothing");
        require(logged.empty() && g_script_moves.already==1,"a move that is done already is counted without a line");
        return;
    }
    if(mode=="gift-host-script-dying") {
        item.destroying=true;
        bool handled=host_transfer_item(3,1,2);
        require(handled,"an item being destroyed is handled");
        require(sent_events==0 && entity.ID_Parent==1,"an item being destroyed is not moved");
        require(logged.empty() && g_script_moves.dying==1,"an item being destroyed is counted without a line");
        handled=host_transfer_item(3,1,1);
        require(handled && g_script_moves.dying==2 && g_script_moves.in_place==0,"not even in place: the stock pair never runs on it");
        return;
    }
    if(mode=="gift-host-script-missing") {
        entity_gone=true;
        bool handled=host_transfer_item(3,1,1);
        require(handled,"a missing item is handled");
        require(logged.size()==1 && logged[0]==Reason::Missing && g_script_moves.refused==1,"a missing item is logged with its data");
        return;
    }
    if(mode.find("gift-host-script")==0) {
        authority=mode!="gift-host-script-offline";
        reject_take=mode=="gift-host-script-refused";
        bool stale=mode=="gift-host-script-stale";
        bool handled=host_transfer_item(3,stale?7:1,2);
        require(handled==authority,"host must consume a refused gift, single player must fall through");
        require(entity.ID_Parent==(mode=="gift-host-script"?2:1),"host script transfer must preserve ownership on failure");
        if(mode=="gift-host-script-stale")
            require(logged.size()==1 && logged[0]==Reason::Moved && g_script_moves.refused==1,"a stale move is logged with its data");
        if(mode=="gift-host-script-refused")
            require(logged.size()==1 && logged[0]==Reason::Engine && g_script_moves.refused==1,"a refused move is logged with its data");
        if(mode=="gift-host-script"||mode=="gift-host-script-offline") require(logged.empty(),"nothing to log");
        return;
    }
    u16 from=1,to=2;
    if(mode=="gift-rejected-take")reject_take=true;
    if(mode=="gift-cannot-take")item.takeable=false;
    if(mode=="gift-recipient-full")receiver.bag.full=true;
    if(mode=="gift-stale-owner")item.parent=&receiver;
    if(mode=="gift-destroying-recipient")receiver.destroying=true;
    if(mode=="gift-drop")to=kNoId;
    if(mode=="gift-ground-take"){from=kNoId;item.parent=nullptr;entity.ID_Parent=kNoId;}
    Reason result=apply_move(3,from,to,nullptr);
    if(mode=="gift-success"||mode=="gift-drop"||mode=="gift-ground-take") {
        require(result==Reason::Ok && entity.ID_Parent==to,"accepted transfer must reach its recipient");
    } else {
        require(result!=Reason::Ok,"invalid transfer must fail");
        require(entity.ID_Parent==1,"failed gift must remain with / return to its sender");
        if(mode!="gift-rejected-take")require(sent_events==0,"reject invalid transfer before detaching");
    }
}
}
