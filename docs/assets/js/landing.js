(() => {
  'use strict';

  document.querySelectorAll('.screen-tour').forEach((tour) => {
    const tablist = tour.querySelector('[data-screen-tabs]');
    if (!tablist) return;

    const tabs = Array.from(tablist.querySelectorAll('[data-screen-target]'));
    const panels = tabs.map((tab) => document.getElementById(tab.dataset.screenTarget));
    if (!tabs.length || tabs.some((tab) => !tab.id) ||
        panels.some((panel) => !panel || !tour.contains(panel))) return;

    const count = tour.querySelector('[data-screen-count]');
    const status = tour.querySelector('[data-screen-status]');
    let active = tabs.findIndex((tab) => `#${tab.dataset.screenTarget}` === location.hash);
    if (active < 0) active = 0;

    tablist.setAttribute('role', 'tablist');
    const wideLayout = window.matchMedia('(min-width: 769px)');
    const updateOrientation = () => tablist.setAttribute('aria-orientation', wideLayout.matches ? 'vertical' : 'horizontal');
    updateOrientation();
    wideLayout.addEventListener('change', updateOrientation);
    if (!tablist.hasAttribute('aria-label') && !tablist.hasAttribute('aria-labelledby')) {
      tablist.setAttribute('aria-label', '앱 화면');
    }
    tabs.forEach((tab, index) => {
      tab.setAttribute('role', 'tab');
      tab.setAttribute('aria-controls', panels[index].id);
      panels[index].setAttribute('role', 'tabpanel');
      panels[index].setAttribute('aria-labelledby', tab.id);
      panels[index].tabIndex = 0;
    });

    const select = (index, focus = false, announce = true) => {
      active = (index + tabs.length) % tabs.length;
      tabs.forEach((tab, tabIndex) => {
        const selected = tabIndex === active;
        tab.classList.toggle('is-active', selected);
        tab.setAttribute('aria-selected', String(selected));
        tab.tabIndex = selected ? 0 : -1;
        panels[tabIndex].hidden = !selected;
      });
      const position = `${active + 1} / ${tabs.length}`;
      if (count) count.textContent = position;
      if (status && announce) {
        const label = panels[active].dataset.screenLabel || tabs[active].textContent.trim();
        status.textContent = `${position} · ${label}`;
      }
      if (focus) tabs[active].focus({ preventScroll: true });
    };

    tabs.forEach((tab, index) => {
      tab.addEventListener('click', (event) => {
        event.preventDefault();
        select(index);
      });
      tab.addEventListener('keydown', (event) => {
        let destination;
        switch (event.key) {
          case 'ArrowLeft':
          case 'ArrowUp':
            destination = index - 1;
            break;
          case 'ArrowRight':
          case 'ArrowDown':
            destination = index + 1;
            break;
          case 'Home':
            destination = 0;
            break;
          case 'End':
            destination = tabs.length - 1;
            break;
          case ' ':
            destination = index;
            break;
          default:
            return;
        }
        event.preventDefault();
        select(destination, true);
      });
    });

    ['previous', 'next'].forEach((direction) => {
      const button = tour.querySelector(`[data-screen-${direction}]`);
      if (!button) return;
      button.hidden = false;
      button.addEventListener('click', () => select(active + (direction === 'next' ? 1 : -1)));
    });

    select(active, false, false);
    tour.classList.add('tour-enhanced');
  });

  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const root = document.documentElement;
  const reveals = Array.from(document.querySelectorAll('.reveal'));
  const flows = Array.from(document.querySelectorAll('.flow-diagram'), (element) => ({
    element,
    frame: 0,
    started: false,
  }));
  const motionToggle = document.querySelector('[data-motion-toggle]');
  const replayButtons = Array.from(document.querySelectorAll('[data-flow-replay]'));
  let paused = false;
  let observer;

  const complete = (flow) => {
    cancelAnimationFrame(flow.frame);
    flow.frame = 0;
    flow.started = true;
    flow.element.classList.add('is-complete');
    flow.element.classList.remove('is-playing');
  };

  const play = (flow, replay = false) => {
    if (reducedMotion.matches) {
      complete(flow);
      return;
    }
    cancelAnimationFrame(flow.frame);
    flow.started = true;
    flow.element.classList.remove('is-complete', 'is-playing');
    if (!replay) {
      flow.element.classList.add('is-playing');
      return;
    }
    // Two frames commit the reset before restarting the finite CSS sequence.
    flow.frame = requestAnimationFrame(() => {
      flow.frame = requestAnimationFrame(() => {
        flow.frame = 0;
        if (!reducedMotion.matches) flow.element.classList.add('is-playing');
      });
    });
  };

  flows.forEach((flow) => {
    flow.element.addEventListener('animationend', () => {
      if (!flow.element.classList.contains('is-playing') || !flow.element.getAnimations) return;
      const unfinished = flow.element.getAnimations({ subtree: true }).some((animation) =>
        animation.playState === 'running' || animation.playState === 'paused');
      if (!unfinished) complete(flow);
    });
  });

  const updateMotion = () => {
    const reduced = reducedMotion.matches;
    const stopped = paused || reduced;
    root.classList.toggle('motion-paused', stopped);
    if (motionToggle) {
      motionToggle.hidden = reduced;
      motionToggle.setAttribute('aria-pressed', String(stopped));
      motionToggle.textContent = stopped ? '모션 재생' : '모션 멈추기';
    }
    replayButtons.forEach((button) => {
      button.hidden = reduced;
      button.disabled = stopped;
    });
    if (reduced) {
      if (observer) observer.disconnect();
      reveals.forEach((element) => element.classList.add('is-visible'));
      flows.forEach(complete);
    }
  };

  if (motionToggle) {
    motionToggle.addEventListener('click', () => {
      if (reducedMotion.matches) return;
      paused = !paused;
      updateMotion();
    });
  }

  replayButtons.forEach((button) => {
    button.addEventListener('click', () => {
      if (paused || reducedMotion.matches) return;
      const container = button.closest('.flow-diagram');
      const targets = container ? flows.filter((flow) => flow.element === container) : flows;
      targets.forEach((flow) => play(flow, true));
    });
  });

  updateMotion();
  reducedMotion.addEventListener('change', updateMotion);

  if (!reducedMotion.matches && 'IntersectionObserver' in window) {
    observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        observer.unobserve(entry.target);
        if (entry.target.classList.contains('reveal')) entry.target.classList.add('is-visible');
        const flow = flows.find((candidate) => candidate.element === entry.target);
        if (flow && !flow.started) play(flow);
      });
    }, { threshold: 0.1 });
    new Set([...reveals, ...flows.map((flow) => flow.element)]).forEach((element) => observer.observe(element));
  } else if (!reducedMotion.matches) {
    // Without an observer, retain readable static content; replay remains manual.
    flows.forEach(complete);
  }
})();
