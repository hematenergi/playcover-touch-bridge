const surface = document.querySelector('#touch-surface');
const state = document.querySelector('#touch-state');
const buttons = [...document.querySelectorAll('[data-touch]')];
const contacts = new Map();

function renderContacts() {
  surface.replaceChildren();
  for (const point of contacts.values()) {
    const marker = document.createElement('span');
    marker.className = 'touch';
    marker.textContent = point.label;
    marker.style.left = `${point.x * 100}%`;
    marker.style.top = `${point.y * 100}%`;
    surface.append(marker);
  }
  state.textContent = contacts.size ? `${contacts.size} independent contact${contacts.size === 1 ? '' : 's'}` : 'No contacts';
  for (const button of buttons) button.setAttribute('aria-pressed', String(contacts.has(`button-${button.dataset.touch}`)));
}

function pointFromEvent(event) {
  const rect = surface.getBoundingClientRect();
  return { x: Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width)), y: Math.max(0, Math.min(1, (event.clientY - rect.top) / rect.height)) };
}

function nextLabel() {
  const used = new Set([...contacts.values()].map(point => point.label));
  for (let label = 1; label <= 10; label++) if (!used.has(label)) return label;
}

surface.addEventListener('pointerdown', event => {
  if (event.button !== 0 || contacts.size >= 10) return;
  surface.setPointerCapture(event.pointerId);
  contacts.set(event.pointerId, { ...pointFromEvent(event), label: nextLabel() });
  renderContacts();
});
surface.addEventListener('pointermove', event => {
  if (!contacts.has(event.pointerId)) return;
  contacts.set(event.pointerId, { ...pointFromEvent(event), label: contacts.get(event.pointerId).label });
  renderContacts();
});
function releasePointer(event) { contacts.delete(event.pointerId); renderContacts(); }
surface.addEventListener('pointerup', releasePointer);
surface.addEventListener('pointercancel', releasePointer);
surface.addEventListener('lostpointercapture', releasePointer);
for (const button of buttons) button.addEventListener('click', () => {
  const id = `button-${button.dataset.touch}`;
  if (contacts.has(id)) contacts.delete(id);
  else if (contacts.size < 10) contacts.set(id, { x: button.dataset.touch === '1' ? .3 : .7, y: .62, label: nextLabel() });
  renderContacts();
});
document.querySelector('#clear-touches').addEventListener('click', () => { contacts.clear(); renderContacts(); });
window.addEventListener('blur', () => { contacts.clear(); renderContacts(); });

const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
const panels = new Map();
function refreshLayout() {
  window.lenis?.resize();
  window.ScrollTrigger?.refresh();
}

function finishPanel(detail) {
  const panel = panels.get(detail);
  detail.open = panel.expanded;
  gsap.set(detail, { clearProps: 'height,overflow,flexGrow' });
  gsap.set(panel.content, { clearProps: 'opacity,transform' });
  refreshLayout();
}

function animatePanel(detail, expanded) {
  const panel = panels.get(detail);
  panel.expanded = expanded;
  panel.summary.setAttribute('aria-expanded', String(expanded));
  gsap.killTweensOf(detail, 'height,flexGrow');
  gsap.killTweensOf(panel.content);
  if (reducedMotion.matches) { finishPanel(detail); return; }

  const desktopSetup = detail.closest('.setup-panels') && matchMedia('(min-width: 701px)').matches;
  if (desktopSetup) {
    const grow = Number(getComputedStyle(detail).flexGrow);
    detail.open = true;
    gsap.fromTo(detail, { flexGrow: grow }, {
      flexGrow: expanded ? 3.2 : 1,
      duration: .5,
      ease: 'power3.inOut',
      onComplete: () => finishPanel(detail),
    });
  } else {
    const start = detail.getBoundingClientRect().height;
    detail.style.height = 'auto';
    detail.open = expanded;
    const end = detail.getBoundingClientRect().height;
    // Keep native details open until the closing tween has actually finished.
    detail.open = true;
    gsap.fromTo(detail, { height: start, overflow: 'hidden' }, {
      height: end,
      duration: .42,
      ease: 'power3.inOut',
      onComplete: () => finishPanel(detail),
    });
  }
  gsap.fromTo(panel.content, { opacity: expanded ? .4 : 1, y: expanded ? 10 : 0 }, {
    opacity: expanded ? 1 : 0,
    y: expanded ? 0 : 6,
    duration: expanded ? .4 : .25,
    ease: 'power2.out',
  });
}

if (window.gsap) {
  document.querySelectorAll('.setup-panels, .faq-cards').forEach(group => {
    const details = [...group.querySelectorAll('details')];
    details.forEach(detail => {
      const summary = detail.querySelector('summary');
      const content = document.createElement('div');
      content.className = 'accordion-content';
      [...detail.childNodes].filter(node => node !== summary).forEach(node => content.append(node));
      detail.append(content);
      // JS owns mutual exclusion so native name= cannot snap a sibling shut before its tween.
      detail.removeAttribute('name');
      panels.set(detail, { summary, content, expanded: detail.open });
      summary.setAttribute('aria-expanded', String(detail.open));
      summary.addEventListener('click', event => {
        event.preventDefault();
        const expanded = !panels.get(detail).expanded;
        if (expanded) details.filter(other => other !== detail && panels.get(other).expanded).forEach(other => animatePanel(other, false));
        animatePanel(detail, expanded);
      });
    });
  });
  function settlePanels() {
    for (const [detail, panel] of panels) {
      gsap.killTweensOf(detail, 'height,flexGrow');
      gsap.killTweensOf(panel.content);
      finishPanel(detail);
    }
  }
  let resizeTimer;
  addEventListener('resize', () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(settlePanels, 150); });
  reducedMotion.addEventListener('change', settlePanels);
}

if (window.gsap && window.ScrollTrigger && window.Lenis) {
  gsap.registerPlugin(ScrollTrigger);
  gsap.matchMedia().add('(prefers-reduced-motion: no-preference)', () => {
    const lenis = new Lenis({ autoRaf: false, anchors: { offset: -32 }, lerp: .12, smoothWheel: true, syncTouch: false });
    window.lenis = lenis;
    lenis.on('scroll', ScrollTrigger.update);
    const tick = time => lenis.raf(time * 1000);
    gsap.ticker.add(tick);
    gsap.ticker.lagSmoothing(0);

    gsap.timeline({ defaults: { ease: 'power3.out' } })
      .fromTo('.hero-picture', { clipPath: 'circle(0% at 50% 50%)' }, { clipPath: 'circle(50% at 50% 50%)', duration: 1.1 }, 0)
      .fromTo('.hero-picture img', { scale: 1.1 }, { scale: 1, duration: 1.1 }, 0)
      .fromTo('.hero-copy h1', { y: 24, opacity: .7 }, { y: 0, opacity: 1, duration: .8 }, .05)
      .fromTo('.hero-copy .hero-intro, .hero-copy .button', { y: 16, opacity: .7 }, { y: 0, opacity: 1, duration: .7, stagger: .08 }, .15);

    document.querySelectorAll('[data-reveal]').forEach(element => {
      const picture = element.matches('figure, .setup-image, .touch-picture');
      gsap.fromTo(element,
        { y: picture ? 0 : 24, scale: picture ? .96 : 1, opacity: .6 },
        { y: 0, scale: 1, opacity: 1, duration: picture ? 1 : .8, ease: 'power3.out', immediateRender: false,
          scrollTrigger: { trigger: element, start: 'top 92%', once: true } });
    });
    gsap.fromTo('.setup-image img', { y: 12 }, { y: -12, ease: 'none',
      scrollTrigger: { trigger: '.setup-image', start: 'top bottom', end: 'bottom top', scrub: true } });
    document.fonts.ready.then(refreshLayout);

    return () => {
      gsap.ticker.remove(tick);
      lenis.destroy();
      if (window.lenis === lenis) delete window.lenis;
    };
  });
}
