import ClaudeLogo from './ClaudeLogo';

type SessionProviderLogoProps = {
  provider?: string | null;
  className?: string;
};

export default function SessionProviderLogo({
  provider: _provider = 'claude',
  className = 'w-5 h-5',
}: SessionProviderLogoProps) {
  return <ClaudeLogo className={className} />;
}
