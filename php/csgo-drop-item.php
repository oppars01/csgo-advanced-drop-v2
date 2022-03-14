<?php
$STEAM_API_KEY = '';

function security($data)
{
    return trim(addslashes(strip_tags(str_replace('"', '＂', $data))));
}
function securityPrint($data)
{
    return trim(html_entity_decode(strip_tags(stripslashes(htmlentities(str_replace('"', '＂', $data))))));
}

header('Content-Type: application/json');
$def_index= intval(security($_GET['def_index']));
if(!empty($def_index)){
    $status = false;
    if(filemtime( 'items.json' ) < time()){
        $data = file_get_contents('https://api.steampowered.com/IEconItems_730/GetSchema/v2/?key='.$STEAM_API_KEY.'&format=json&language=en');
        if($data) file_put_contents("items.json", $data);
    }
    if(!$data)$data= file_get_contents('items.json');
    if($data){
        $data_json = json_decode($data, true);
        foreach($data_json['result']['items'] as $item){
            if($def_index == security($item['defindex'])){
                $status = true;
                $result_array = ["success" => 1, "item_name" => security($item['item_name']),  "item_image" => security($item['image_url']),  "market_url" => 'https://steamcommunity.com/market/priceoverview/?appid=730&currency=17&market_hash_name='.rawurlencode(security($item['item_name']))];
                break;
            }
        }
        if(!$status)$result_array = ["success" => 0,"error" => 'Drop ögesi bulunamadı.'];
    }else $result_array = ["success" => 0,"error" => 'Drop listesi bulunamadı.'];
}else $result_array = ["success" => 0,"error" => 'Hatalı parametre.'];

echo '"DropItem"
{
';
    foreach ($result_array as $key => $value) {
        $kv .= '"'.securityPrint($key).'"  "'.securityPrint($value).'"
        ';
    }
        echo '
    "result"
    {
        '.$kv.'
    }';
    echo '
    
}';
?>