import { useCallback, useState } from 'react';
import type { ReactNode } from 'react';
import { IS_PLATFORM } from '../../../constants/config';
import { useAuth } from '../context/AuthContext';
import Onboarding from '../../onboarding/view/Onboarding';
import AuthLoadingScreen from './AuthLoadingScreen';
import LoginForm from './LoginForm';
import SetupForm from './SetupForm';
import { TotpSetupScreen } from './TotpSetupScreen';

type ProtectedRouteProps = {
  children: ReactNode;
};

export default function ProtectedRoute({ children }: ProtectedRouteProps) {
  const { user, isLoading, needsSetup, hasCompletedOnboarding, refreshOnboardingStatus } = useAuth();

  // Tracks whether the user has set up TOTP within this session (bypasses the
  // gate if they just completed setup without a page reload).
  const [totpSetupDone, setTotpSetupDone] = useState(false);

  const handleOnboardingComplete = useCallback(async () => {
    await refreshOnboardingStatus();
  }, [refreshOnboardingStatus]);

  const handleTotpDone = useCallback(() => {
    setTotpSetupDone(true);
  }, []);

  if (isLoading) {
    return <AuthLoadingScreen />;
  }

  if (IS_PLATFORM) {
    if (!hasCompletedOnboarding) {
      return <Onboarding onComplete={handleOnboardingComplete} />;
    }

    return <>{children}</>;
  }

  if (needsSetup) {
    return <SetupForm />;
  }

  if (!user) {
    return <LoginForm />;
  }

  if (!hasCompletedOnboarding) {
    return <Onboarding onComplete={handleOnboardingComplete} />;
  }

  // After onboarding is complete, require TOTP setup if not already enabled.
  if (!totpSetupDone && user.totpEnabled === false) {
    return <TotpSetupScreen onDone={handleTotpDone} />;
  }

  return <>{children}</>;
}
