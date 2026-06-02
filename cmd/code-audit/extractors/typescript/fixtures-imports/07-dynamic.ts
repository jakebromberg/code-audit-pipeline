export async function loadShared() {
  const m = await import('@wxyc/shared');
  const lang = 'en';
  const locale = await import(`./locales/${lang}`);
  return { m, locale };
}
