-- Implicit CAD. Copyright (C) 2011, Christopher Olah (chris@colah.ca)
-- Copyright (C) 2016, Julia Longtin (julial@turinglace.com)
-- Released under the GNU AGPLV3+, see LICENSE

{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE UndecidableInstances #-}

module Graphics.Implicit.Export.Symbolic.CoerceSymbolic2 (coerceSymbolic2) where

import Graphics.Implicit.Definitions
import Graphics.Implicit.Export.DiscreteAproxable

import Graphics.Implicit.Operations
import Graphics.Implicit.Primitives

coerceSymbolic2 :: SymbolicObj2 -> BoxedObj2
coerceSymbolic2 (EmbedBoxedObj2 boxedObj) = boxedObj
coerceSymbolic2 (RectR r a b) = rectR r a b
coerceSymbolic2 (Circle r ) = circle r
coerceSymbolic2 (PolygonR r points) = polygonR r points
coerceSymbolic2 (UnionR2 r objs) = unionR r (fmap coerceSymbolic2 objs)
coerceSymbolic2 (IntersectR2 r objs) = intersectR r (fmap coerceSymbolic2 objs)
coerceSymbolic2 (DifferenceR2 r objs) = differenceR r (fmap coerceSymbolic2 objs)
coerceSymbolic2 (Complement2 obj) = complement $ coerceSymbolic2 obj
coerceSymbolic2 (Shell2 w obj) = shell w $ coerceSymbolic2 obj
coerceSymbolic2 (Translate2 v obj) = translate v $ coerceSymbolic2 obj
coerceSymbolic2 (Scale2 s obj) = scale s $ coerceSymbolic2 obj
coerceSymbolic2 (Rotate2 a obj) = rotateXY a $ coerceSymbolic2 obj
coerceSymbolic2 (Outset2 d obj) = outset 2 $ coerceSymbolic2 obj

