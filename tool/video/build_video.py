#!/usr/bin/env python3
"""Builds the kickFile how-to video: 1920x1080, captions + macOS 'say' narration.

Scenes are either a rendered desktop screen (PNG from test/video) in a Mac/Windows
window frame, a real Android screen recording in a phone frame, or a title card.
"""
import html
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
DESK = os.path.join(ROOT, 'desktop')
ANDR = os.path.join(ROOT, 'android')
WORK = os.path.join(ROOT, 'work')
OUT = sys.argv[1]
CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
ICON = os.path.join(ROOT, '..', 'icons', 'full_master.png')
os.makedirs(WORK, exist_ok=True)

VOICE = 'Samantha'
RATE = '172'

# (id, kind, source, platform label, step title, narration, extra)
SCENES = [
    ('s01', 'card', 'title', '', 'kickFile',
     'kickFile. Move files between your phone and your laptop, over Wi-Fi or a hotspot. No cable, no account, no internet.', {}),
    ('s02', 'card', 'install', '', 'Get the apps',
     'Install kickFile on both devices: the Android app on your phone, and the app for Mac or Windows on your laptop.', {}),
    ('s03', 'mac', 'mac_welcome', 'macOS', 'Set up your Mac',
     'On your Mac, open kickFile, check the name your phone will see, and click Get started.', {}),
    ('s04', 'mac', 'mac_firstrun', 'macOS', 'First run',
     'Until your phone is set up, kickFile shows a QR code to download the phone app.', {}),
    ('s05', 'phone', 'r1', 'Android', 'Set up your phone',
     'On your phone, open kickFile, give it a name, and tap Get started. Devices on the same Wi-Fi show up by themselves.', {'ss': 3.0, 'to': 24.0}),
    ('s06', 'phone', 'r2', 'Android', 'Send from your phone',
     'To send from your phone, tap your laptop, choose Files, Photos, a Folder or Text, and pick what to send. That is three taps.', {'ss': 0.5, 'to': 16.5}),
    ('s07', 'mac', 'mac_trust', 'macOS', 'Trust it once',
     'The first time, your Mac asks whether to trust the phone. Check that both screens show the same six digit code, then choose Trust and auto-accept.', {}),
    ('s08', 'mac', 'mac_receiving', 'macOS', 'Receiving',
     'The file goes straight to your Mac over your local network, encrypted.', {}),
    ('s09', 'mac', 'mac_done', 'macOS', 'Done',
     'When it is done, it is checked and saved in Downloads, kickFile. Click Open, or Show in Finder.', {}),
    ('s10', 'mac', 'mac_drop', 'macOS', 'Send from your Mac',
     'To send from your Mac, drag files onto your phone in the kickFile window. Or click the phone to choose files.', {}),
    ('s11', 'mac', 'mac_sending', 'macOS', 'Sending',
     'You can see the speed and the time left. Keep kickFile open on your phone until it finishes.', {}),
    ('s12', 'phone', 'r3', 'Android', 'Receive on your phone',
     'Your phone shows who is sending and what. Tap Accept. Photos and videos go to your gallery, and other files to Downloads.', {'ss': 0.5, 'to': 27.0}),
    ('s13', 'win', 'win_home', 'Windows', 'On Windows',
     'On Windows it works exactly the same way.', {}),
    ('s14', 'win', 'win_close', 'Windows', 'Always ready',
     'Close the window and kickFile keeps running in the system tray, so your phone can always send to your PC.', {}),
    ('s15', 'phone', 'r4', 'Android', "Don't see your device?",
     "Don't see your device? Tap Don't see your device. kickFile checks your connection, and you can always connect with a QR code instead.", {'ss': 2.0, 'to': 16.5}),
    ('s16', 'mac', 'mac_hotspot', 'macOS', 'No Wi-Fi?',
     "No Wi-Fi? Turn on your phone's hotspot and join it from your laptop. kickFile doesn't use your mobile data.", {}),
    ('s17', 'mac', 'mac_settings', 'macOS', 'Settings',
     'In Settings you can rename this device, hide it, choose where files go, and manage trusted devices.', {}),
    ('s18', 'card', 'end', '', 'kickFile',
     'kickFile. Fast, private, and full quality.', {}),
]

CSS = """
:root{--accent:#6741D9;--ink:#17151C;--muted:#56535E}
*{box-sizing:border-box;margin:0;padding:0}
html,body{width:1920px;height:1080px;overflow:hidden}
body{font-family:-apple-system,"SF Pro Display","Helvetica Neue",Arial,sans-serif;color:var(--ink);
 background:radial-gradient(1200px 800px at 15% 20%,#EFE9FF 0%,#F6F4FA 45%,#ECEAF3 100%)}
.media{position:absolute;left:120px;top:0;width:920px;height:1080px;display:flex;align-items:center;justify-content:center}
.panel{position:absolute;left:1100px;top:0;width:720px;height:1080px;display:flex;flex-direction:column;justify-content:center;gap:28px}
.chip{align-self:flex-start;font-size:26px;font-weight:600;color:var(--accent);background:#E8E0FF;padding:10px 22px;border-radius:999px}
.title{font-size:64px;font-weight:800;letter-spacing:-1px;line-height:1.05}
.caption{font-size:36px;line-height:1.35;color:var(--muted)}
.step{font-size:24px;color:#8A8594;font-weight:600;letter-spacing:2px}
.brand{position:absolute;left:60px;bottom:44px;display:flex;align-items:center;gap:14px;font-size:26px;font-weight:700;color:#3a3545}
.brand img{width:40px;height:40px}
/* mac window */
.macwin{width:540px;border-radius:14px;overflow:hidden;box-shadow:0 30px 80px rgba(30,20,60,.28),0 0 0 1px rgba(0,0,0,.08);background:#fff}
.macbar{height:40px;background:#ECEAF1;display:flex;align-items:center;padding:0 16px;gap:8px;position:relative}
.macbar i{width:13px;height:13px;border-radius:50%;display:block}
.macbar span{position:absolute;left:0;right:0;text-align:center;font-size:15px;font-weight:600;color:#55505f}
/* windows window */
.winwin{width:540px;overflow:hidden;box-shadow:0 26px 70px rgba(30,20,60,.28),0 0 0 1px rgba(0,0,0,.12);background:#fff;border-radius:8px}
.winbar{height:40px;background:#F3F3F3;display:flex;align-items:center;justify-content:space-between;padding-left:14px;font-size:15px;color:#222}
.winbar .t{display:flex;align-items:center;gap:10px}.winbar .t img{width:18px;height:18px}
.winbar .b{display:flex}.winbar .b div{width:46px;height:40px;display:flex;align-items:center;justify-content:center;font-size:14px;color:#333}
.shot{display:block;width:540px}
/* phone */
.phone{width:466px;height:1010px;border-radius:58px;background:#16141c;padding:16px;box-shadow:0 30px 80px rgba(30,20,60,.35)}
.screen{width:434px;height:978px;border-radius:44px;background:#000;overflow:hidden}
/* cards */
.card{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:30px;text-align:center}
.card img.logo{width:160px;height:160px}
.card h1{font-size:110px;font-weight:800;letter-spacing:-3px}
.card p{font-size:40px;color:var(--muted);max-width:1300px;line-height:1.35}
.plats{display:flex;gap:40px;margin-top:20px}
.plat{background:#fff;border-radius:28px;padding:34px 46px;box-shadow:0 14px 40px rgba(30,20,60,.12);text-align:left;min-width:420px}
.plat b{font-size:40px;display:block;margin-bottom:10px}.plat span{font-size:28px;color:var(--muted)}
.foot{position:absolute;bottom:40px;font-size:22px;color:#8A8594}
"""


def page(body):
    return f'<!doctype html><html><head><meta charset="utf-8"><style>{CSS}</style></head><body>{body}</body></html>'


def panel(i, label, title, text):
    chip = f'<div class="chip">{html.escape(label)}</div>' if label else ''
    return (f'<div class="panel"><div class="step">STEP {i}</div>{chip}'
            f'<div class="title">{html.escape(title)}</div><div class="caption">{html.escape(text)}</div></div>'
            f'<div class="brand"><img src="file://{ICON}">kickFile</div>')


def scene_html(i, kind, src, label, title, text):
    if kind == 'card':
        if src == 'title':
            return page(f'<div class="card"><img class="logo" src="file://{ICON}"><h1>kickFile</h1>'
                        f'<p>Move files between your phone and your laptop.<br>Over Wi-Fi or a hotspot. No cable, no account, no internet.</p></div>')
        if src == 'install':
            plats = ''.join(f'<div class="plat"><b>{a}</b><span>{b}</span></div>' for a, b in [
                ('Android', 'kickFile app on your phone'), ('macOS', 'kickFile for Mac (DMG)'), ('Windows', 'kickFile for Windows')])
            return page(f'<div class="card"><h1 style="font-size:84px">Install kickFile on both devices</h1>'
                        f'<div class="plats">{plats}</div><p>Both need to be on the same Wi-Fi, or on your phone\'s hotspot.</p></div>')
        return page(f'<div class="card"><img class="logo" src="file://{ICON}"><h1>kickFile</h1>'
                    f'<p>Fast, private, full quality.<br>No cable. No cloud. No account.</p>'
                    f'<div class="foot">Android: screen recordings of the app. Mac and Windows: the app\'s own screens, rendered from the same build.</div></div>')
    if kind == 'mac':
        win = (f'<div class="macwin"><div class="macbar"><i style="background:#FF5F57"></i><i style="background:#FEBC2E"></i>'
               f'<i style="background:#28C840"></i><span>kickFile</span></div><img class="shot" src="file://{DESK}/{src}.png"></div>')
    elif kind == 'win':
        win = (f'<div class="winwin"><div class="winbar"><div class="t"><img src="file://{ICON}">kickFile</div>'
               f'<div class="b"><div>&#8212;</div><div>&#9633;</div><div>&#10005;</div></div></div>'
               f'<img class="shot" src="file://{DESK}/{src}.png"></div>')
    else:  # phone: screen left empty, the recording is overlaid by ffmpeg
        win = '<div class="phone"><div class="screen" id="screen"></div></div>'
    return page(f'<div class="media">{win}</div>{panel(i, label, title, text)}')


def run(*cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def duration(path):
    out = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', path],
                         capture_output=True, text=True, check=True).stdout.strip()
    return float(out)


# Phone screen position on the 1920x1080 canvas (see CSS): media box centred in left area.
MEDIA_X, MEDIA_W = 120, 920
PHONE_W, PHONE_H = 466, 1010
SCREEN_X = MEDIA_X + (MEDIA_W - PHONE_W) // 2 + 16
SCREEN_Y = (1080 - PHONE_H) // 2 + 16
SCREEN_W, SCREEN_H = 434, 978

# Rounded-corner mask for the phone screen, made once.
MASK = os.path.join(WORK, 'screen_mask.png')
R = 44
run('ffmpeg', '-y', '-f', 'lavfi', '-i', f'color=black:s={SCREEN_W}x{SCREEN_H}', '-frames:v', '1', '-vf',
    f"format=gray,geq=lum='if(gt(abs(X-W/2),W/2-{R})*gt(abs(Y-H/2),H/2-{R}),"
    f"if(lte(hypot(abs(X-W/2)-(W/2-{R}),abs(Y-H/2)-(H/2-{R})),{R}),255,0),255)'", MASK)

segments = []
for n, (sid, kind, src, label, title, text, extra) in enumerate(SCENES, start=1):
    h = os.path.join(WORK, f'{sid}.html')
    png = os.path.join(WORK, f'{sid}.png')
    with open(h, 'w') as f:
        f.write(scene_html(n, kind, src, label, title, text))
    run(CHROME, '--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
        '--allow-file-access-from-files', '--window-size=1920,1080', f'--screenshot={png}', f'file://{h}')

    aiff = os.path.join(WORK, f'{sid}.aiff')
    run('say', '-v', VOICE, '-r', RATE, '-o', aiff, text)
    voice = duration(aiff)

    seg = os.path.join(WORK, f'{sid}.mp4')
    if kind == 'phone':
        clip = os.path.join(ANDR, f'{src}.mp4')
        ss, to = extra['ss'], extra['to']
        dur = max(to - ss, voice + 1.2)
        # Hold the last frame if the narration runs longer than the clip.
        vf = (f"[1:v]trim=start={ss}:end={to},setpts=PTS-STARTPTS,fps=30,scale={SCREEN_W}:{SCREEN_H},format=yuva420p,"
              f"tpad=stop_mode=clone:stop_duration=30[clip];[3:v]format=gray,scale={SCREEN_W}:{SCREEN_H}[m];"
              f"[clip][m]alphamerge[ph];"
              f"[0:v][ph]overlay={SCREEN_X}:{SCREEN_Y}:shortest=0,trim=duration={dur},"
              f"fade=t=in:st=0:d=0.35,fade=t=out:st={dur - 0.35}:d=0.35,format=yuv420p[v]")
        run('ffmpeg', '-y', '-loop', '1', '-framerate', '30', '-t', f'{dur}', '-i', png, '-i', clip, '-i', aiff,
            '-loop', '1', '-framerate', '30', '-t', f'{dur}', '-i', MASK,
            '-filter_complex', vf + f';[2:a]apad,atrim=0:{dur},aresample=48000[a]',
            '-map', '[v]', '-map', '[a]', '-c:v', 'libx264', '-preset', 'medium', '-crf', '20', '-r', '30',
            '-c:a', 'aac', '-b:a', '160k', '-t', f'{dur}', seg)
    else:
        dur = voice + (1.6 if kind == 'card' else 1.4)
        # Gentle push-in so still screens don't feel frozen.
        vf = (f"[0:v]scale=2304:1296,zoompan=z='min(1+0.00035*on,1.04)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':"
              f"d={int(dur * 30) + 1}:s=1920x1080:fps=30,trim=duration={dur},"
              f"fade=t=in:st=0:d=0.35,fade=t=out:st={dur - 0.35}:d=0.35,format=yuv420p[v]")
        run('ffmpeg', '-y', '-loop', '1', '-framerate', '30', '-t', f'{dur}', '-i', png, '-i', aiff,
            '-filter_complex', vf + f';[1:a]adelay=300|300,apad,atrim=0:{dur},aresample=48000[a]',
            '-map', '[v]', '-map', '[a]', '-c:v', 'libx264', '-preset', 'medium', '-crf', '20', '-r', '30',
            '-c:a', 'aac', '-b:a', '160k', '-t', f'{dur}', seg)
    segments.append((sid, seg, dur))
    print(f'{sid} {kind:5} {dur:5.1f}s  {title}', flush=True)

lst = os.path.join(WORK, 'list.txt')
with open(lst, 'w') as f:
    for _, seg, _ in segments:
        f.write(f"file '{seg}'\n")
run('ffmpeg', '-y', '-f', 'concat', '-safe', '0', '-i', lst, '-c:v', 'libx264', '-preset', 'medium', '-crf', '20',
    '-c:a', 'aac', '-b:a', '160k', '-movflags', '+faststart', OUT)

# Subtitles file alongside the video (same text as the captions).
t = 0.0
srt = []
for k, ((sid, _, dur), sc) in enumerate(zip(segments, SCENES), start=1):
    def ts(x):
        ms = int(round(x * 1000))
        return f'{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d},{ms % 1000:03d}'
    srt.append(f'{k}\n{ts(t + 0.3)} --> {ts(t + dur - 0.3)}\n{sc[5]}\n')
    t += dur
with open(os.path.splitext(OUT)[0] + '.srt', 'w') as f:
    f.write('\n'.join(srt))
print(json.dumps({'out': OUT, 'seconds': round(t, 1)}))
