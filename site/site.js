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

if (!matchMedia('(prefers-reduced-motion: reduce)').matches && 'IntersectionObserver' in window) {
  const observer = new IntersectionObserver(entries => {
    entries.filter(entry => entry.isIntersecting).forEach((entry, index) => {
      const isPicture = entry.target.matches('figure, .setup-image, .touch-picture');
      entry.target.animate(isPicture
        ? [{ transform: 'scale(.96)', opacity: .5 }, { transform: 'scale(1)', opacity: 1 }]
        : [{ transform: 'translateY(24px)', opacity: .55 }, { transform: 'translateY(0)', opacity: 1 }],
      { duration: isPicture ? 1000 : 800, delay: Math.min(index, 3) * 75, easing: 'cubic-bezier(.16,1,.3,1)' });
      observer.unobserve(entry.target);
    });
  }, { threshold: .12 });
  document.querySelectorAll('[data-reveal]').forEach(element => observer.observe(element));
}
