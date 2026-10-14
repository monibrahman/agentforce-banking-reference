"""Hand-laid-out architecture diagram (SVG -> PNG via headless Edge). Explicit coordinates, so no arrow runs behind a box.

usage: python -I -X utf8 arch_svg.py <out_dir>
"""
import os, subprocess, sys
from xml.sax.saxutils import escape

OUT = os.path.abspath(sys.argv[1])
ACCENT = '#1F4E79'
FILL = '#EAF1F8'
W, H = 1600, 960
parts = []

def box(x, y, w, h, lines, fill=FILL, stroke=ACCENT, dash=False, bold_first=True, size=19):
    d = ' stroke-dasharray="7 5"' if dash else ''
    parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{fill}" stroke="{stroke}" stroke-width="2"{d}/>')
    lh = size + 5
    top = y + h / 2 - (len(lines) - 1) * lh / 2 + size * 0.35
    for i, t in enumerate(lines):
        weight = '700' if (i == 0 and bold_first) else '400'
        parts.append(f'<text x="{x + w / 2}" y="{top + i * lh}" text-anchor="middle" font-size="{size}" font-weight="{weight}" fill="#1A1A1A">{escape(t)}</text>')

def arrow(points, label=None, lx=None, ly=None, anchor='middle', both=False):
    pts = ' '.join(f'{x},{y}' for x, y in points)
    start = ' marker-start="url(#ah)"' if both else ''
    parts.append(f'<polyline points="{pts}" fill="none" stroke="#404040" stroke-width="2" marker-end="url(#ah)"{start}/>')
    if label:
        parts.append(f'<text x="{lx}" y="{ly}" text-anchor="{anchor}" font-size="16" font-style="italic" fill="#404040">{escape(label)}</text>')

# Row 1: entry points
box(300, 30, 340, 70, ['Generate Summary button', 'quick action on Client_Meeting__c'])
box(900, 30, 440, 70, ['Banker Assistant agent (v5)', 'employee agent, runs as the banker'])
# Row 2
box(300, 160, 340, 70, ['Screen Flow', 'Generate_Client_Meeting_Summary'])
box(760, 160, 320, 70, ['Find Client Meetings', 'FindClientMeetingsAction'])
box(1160, 160, 320, 70, ['Find Client', 'FindClientAction'])
# Row 3: guards
box(760, 280, 320, 100, ['Guard: selected_meeting_id', 'set when exactly one match;', 'action available only when set;', 'input bound; cleared after use'], fill='#FFFFFF', dash=True, size=16)
box(1160, 280, 320, 100, ['Guard: selected_account_id', 'set when exactly one match;', 'action available only when set;', 'input bound; cleared after use'], fill='#FFFFFF', dash=True, size=16)
# Row 4: services and record
box(20, 430, 240, 80, ['Client_Meeting__c', 'summary fields + PDF file'], fill='#FFFFFF')
box(300, 430, 340, 80, ['Generate Client Meeting Summary', 'ClientSummaryService'])
box(1160, 430, 320, 80, ['Answer Client Question', 'MeetingPrepService'])
# Row 5: the pattern band
parts.append(f'<rect x="20" y="570" width="1560" height="200" rx="10" fill="#F7F9FC" stroke="{ACCENT}" stroke-width="1.5"/>')
parts.append(f'<text x="40" y="596" font-size="19" font-weight="700" fill="{ACCENT}">The same five stages for both services</text>')
box(40, 620, 270, 90, ['1. Context', 'ClientContextBuilder', 'USER_MODE, source ids [S#],', 'budget, untrusted notes'], size=16)
box(340, 620, 270, 90, ['2. Template', 'ILlmGateway', 'PromptTemplateGateway'], size=16)
box(640, 620, 260, 90, ['3. Validate', 'SummaryValidator', 'CitationValidator'], size=16)
box(1060, 620, 240, 90, ['4. Fallback', 'data-only summary', 'or message-only answer'], size=16)
box(1340, 620, 220, 90, ['5. Log', 'AiActionSupport', '.logRow'], size=16)
# Row 6
box(295, 830, 360, 100, ['Prompt Builder (Flex, GPT 5.4)', 'Client_Meeting_Summary _5', 'Meeting_Prep_QA _2', 'grounded by the context classes'], fill='#FFFFFF', size=16)
box(1330, 830, 250, 100, ['AI_Generation_Log__c', 'one row per request', 'Private; AI_Ops + admins'], fill='#FFFFFF', size=16)

# Arrows
arrow([(470, 100), (470, 160)])                                   # button -> flow
arrow([(1060, 100), (1060, 130), (920, 130), (920, 160)])         # agent -> FCM
arrow([(1180, 100), (1180, 130), (1320, 130), (1320, 160)])       # agent -> FC
arrow([(920, 230), (920, 280)])                                   # FCM -> guard
arrow([(1320, 230), (1320, 280)])                                 # FC -> guard
arrow([(470, 230), (470, 430)])                                   # flow -> CSS
arrow([(920, 380), (920, 405), (600, 405), (600, 430)])           # guard -> CSS
arrow([(1320, 380), (1320, 430)])                                 # guard -> MPS
arrow([(300, 470), (260, 470)])                                   # CSS -> record
arrow([(470, 510), (470, 570)], 'Option A', 480, 548, 'start')    # CSS -> band
arrow([(1320, 510), (1320, 570)], 'Option B', 1330, 548, 'start') # MPS -> band
arrow([(310, 665), (340, 665)])                                   # context -> template
arrow([(610, 665), (640, 665)])                                   # template -> validate
arrow([(900, 665), (1060, 665)], 'invalid after', 980, 652, 'middle')
parts.append('<text x="980" y="688" text-anchor="middle" font-size="16" font-style="italic" fill="#404040">one plain retry</text>')
arrow([(1300, 665), (1340, 665)])                                 # fallback -> log
arrow([(770, 710), (770, 745), (1400, 745), (1400, 710)], 'valid or repaired', 1085, 763, 'middle')
arrow([(475, 710), (475, 830)], both=True)                        # template <-> prompt builder
arrow([(1490, 710), (1490, 830)])                                 # log -> log object

svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
       f'font-family="Calibri, Segoe UI, Arial, sans-serif">'
       '<defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">'
       '<path d="M0,0 L10,5 L0,10 z" fill="#404040"/></marker></defs>'
       f'<rect width="{W}" height="{H}" fill="#FFFFFF"/>' + ''.join(parts) + '</svg>')
html = f'<!doctype html><html><head><meta charset="utf-8"><style>html,body{{margin:0;padding:0;background:#fff}}</style></head><body>{svg}</body></html>'
os.makedirs(OUT, exist_ok=True)
open(os.path.join(OUT, 'architecture.svg'), 'w', encoding='utf-8').write(svg)
hp = os.path.join(OUT, 'architecture.html')
open(hp, 'w', encoding='utf-8').write(html)
png = os.path.join(OUT, 'architecture.png')
if os.path.exists(png):
    os.remove(png)
import time
edge = r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
subprocess.run([edge, '--headless=new', '--disable-gpu', '--hide-scrollbars', f'--window-size={W},{H}',
                '--force-device-scale-factor=2', '--user-data-dir=' + os.path.join(OUT, 'edge_profile'), f'--screenshot={png}', 'file:///' + hp.replace('\\', '/')],
               check=True, capture_output=True, timeout=120)
print('wrote', png, os.path.getsize(png))
