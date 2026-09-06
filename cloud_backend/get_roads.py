import urllib.request
import json

overpass_url = 'http://overpass-api.de/api/interpreter'
overpass_query = '''
[out:json];
way(around:1000, 30.3165, 78.0322)[highway~"^(primary|secondary|tertiary)$"];
node(w);
out skel 10;
'''
req = urllib.request.Request(overpass_url, data=overpass_query.encode('utf-8'))
with urllib.request.urlopen(req) as response:
    data = json.loads(response.read().decode('utf-8'))
    for element in data['elements']:
        if element['type'] == 'node':
            print(f'{element["lat"]}, {element["lon"]}')
