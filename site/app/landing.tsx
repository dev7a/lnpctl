'use client';
import { useRef, useState } from 'react';
import { sitePath } from '@/lib/site-path';
import { useVideoSource } from '@/hooks/use-video-source';
import { ArrowRight, ArrowUpRight, Play, ShieldAlert } from 'lucide-react';
import { Button } from '@/components/ui/button';

export default function Landing() {
  const videoSource = useVideoSource(sitePath('/media/full-walkthrough/lnpctl-quick-walkthrough.mp4?v=ellen-v3'));
  const video = useRef<HTMLVideoElement>(null);
  const [started, setStarted] = useState(false);
  const [error, setError] = useState('');
  async function play() {
    try { await video.current?.play(); setStarted(true); setError(''); }
    catch { setError('Use the video controls to start playback.'); }
  }
  return <div className="landing">
    <a href="#tutorial" className="skip-link">Skip to the video tutorial</a>
    <header className="landing-nav"><a href={sitePath('/')} className="brand">lnpctl<span>_</span></a><nav aria-label="Main navigation"><a href={sitePath('/guide/')}>Read the guide</a><a href="https://github.com/dev7a/lnpctl">Source <ArrowUpRight size={16}/></a></nav></header>
    <main>
      <section className="landing-hero" aria-labelledby="landing-title">
        <div className="hero-copy"><p className="hero-kicker">macOS / Local Network permissions</p><h1 id="landing-title">Clean up permissions<br/><span>old apps leave behind.</span></h1><p className="hero-description">Select the stale entries you recognize. Prepare a backup, then apply the cleanup from macOS Recovery.</p><div className="hero-actions"><Button className="hero-primary" render={<a href={sitePath('/guide/')}/>}>Follow the guide <ArrowRight size={18}/></Button><span>Apple silicon · v0.1.4</span></div><aside className="hero-risk"><ShieldAlert size={23} aria-hidden="true"/><p><strong>Very experimental.</strong> Run at your own risk and peril. Uses private macOS APIs and edits an undocumented configuration format. Back up your Mac first.</p></aside></div>
        <figure id="tutorial" className="hero-film"><div className="film-heading"><span>The complete cleanup workflow</span><span>01:28 / English narration & subtitles</span></div><div className="film-screen"><video src={videoSource} ref={video} controls playsInline preload="metadata" poster={sitePath('/media/full-walkthrough/poster.jpg')} aria-label="Full macOS cleanup and Recovery walkthrough" onPlay={()=>setStarted(true)}><track kind="subtitles" src={sitePath('/media/full-walkthrough/lnpctl-quick-walkthrough.en.vtt')} srcLang="en" label="English" default/>Your browser cannot play this video. <a href={sitePath('/media/full-walkthrough/lnpctl-quick-walkthrough.mp4?v=ellen-v3')}>Download the video.</a></video>{!started&&<Button className="film-play" disabled={!videoSource} onClick={play} aria-label="Play the Recovery tutorial"><Play size={25} fill="currentColor"/><span>{videoSource ? 'Watch the walkthrough' : 'Loading walkthrough…'}</span></Button>}</div><figcaption>Real recording: select in Ghostty, apply in Recovery, then verify in Settings. Pauses cut, navigation accelerated, and key steps enlarged. English narration with subtitles on by default.</figcaption>{error&&<p role="status" className="film-error">{error}</p>}</figure>
      </section>
      <section className="landing-flow" aria-label="The cleanup process"><a href={sitePath('/guide/#select')}><span className="flow-index">01</span><div><h2>Choose what goes.</h2><p>Select known unwanted entries and review the full list.</p></div><ArrowUpRight aria-hidden="true"/></a><a href={sitePath('/guide/#recovery')}><span className="flow-index">02</span><div><h2>Take it to Recovery.</h2><p>Save your checklist, mount Data, and run the prepared launcher.</p></div><ArrowUpRight aria-hidden="true"/></a><a href={sitePath('/guide/#apply')}><span className="flow-index">03</span><div><h2>Apply. Reboot. Check.</h2><p>Confirm the change, then test the apps you kept.</p></div><ArrowUpRight aria-hidden="true"/></a></section>
      <section className="landing-caution"><div><p className="hero-kicker">Before you touch your settings</p><h2>A backup is not a guarantee.</h2></div><div><p>A bug, a wrong selection, or a macOS update could break network access or damage settings. Try a disposable VM before a Mac you depend on.</p><p>The cleanup has worked in disposable Tart VMs and on the developer’s own Mac. That does not guarantee safety on other machines or macOS versions.</p></div></section>
    </main><footer className="landing-footer"><span>lnpctl / Experimental Local Network cleanup</span><a href={sitePath('/guide/#restore')}>Restoring a backup <ArrowUpRight size={15}/></a></footer>
  </div>;
}
