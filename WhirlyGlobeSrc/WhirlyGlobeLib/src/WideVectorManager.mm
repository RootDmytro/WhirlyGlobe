/*
 *  WideVectorManager.mm
 *  WhirlyGlobeLib
 *
 *  Created by Steve Gifford on 4/29/14.
 *  Copyright 2011-2014 mousebird consulting. All rights reserved.
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *  http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 *
 */

#import "WideVectorManager.h"
#import "NSDictionary+Stuff.h"
#import "UIColor+Stuff.h"
#import "FlatMath.h"

using namespace WhirlyKit;
using namespace Eigen;

@implementation WhirlyKitWideVectorInfo

- (void)parseDesc:(NSDictionary *)desc
{
    _color = [desc objectForKey:@"color" checkType:[UIColor class] default:[UIColor whiteColor]];
    _minVis = [desc floatForKey:@"minVis" default:DrawVisibleInvalid];
    _maxVis = [desc floatForKey:@"maxVis" default:DrawVisibleInvalid];
    _fade = [desc floatForKey:@"fade" default:0.0];
    _drawPriority = [desc intForKey:@"drawPriority" default:0];
    _enable = [desc boolForKey:@"enable" default:true];
    _shader = [desc intForKey:@"shader" default:EmptyIdentity];
    _width = [desc floatForKey:@"width" default:2.0];
    _coordType = (WhirlyKit::WideVectorCoordsType)[desc enumForKey:@"wideveccoordtype" values:@[@"real",@"screen"] default:WideVecCoordScreen];
    _joinType = (WhirlyKit::WideVectorLineJoinType)[desc enumForKey:@"wideveclinejointype" values:@[@"miter",@"round",@"bevel"] default:WideVecMiterJoin];
    _capType = (WhirlyKit::WideVectorLineCapType)[desc enumForKey:@"wideveclinecaptype" values:@[@"butt",@"round",@"square"] default:WideVecButtCap];
    _texID = [desc intForKey:@"texture" default:EmptyIdentity];
    _repeatSize = [desc floatForKey:@"repeatSize" default:6371000.0 / 20];
    _miterLimit = [desc floatForKey:@"miterLimit" default:2.0];
}

@end

namespace WhirlyKit
{

class WideVectorBuilder
{
public:
    WideVectorBuilder(WhirlyKitWideVectorInfo *vecInfo,const Point3d &center,const RGBAColor inColor)
    : vecInfo(vecInfo), angleCutoff(DegToRad(30.0)), texOffset(0.0), center(center), edgePointsValid(false)
    {
//        color = [vecInfo.color asRGBAColor];
        color = inColor;
    }
    
    // Intersect widened lines for the miter case
    bool intersectWideLines(const Point3d &p0,const Point3d &p1,const Point3d &p2,const Point3d &n0,const Point3d &n1,Point3d &iPt,double &t0,double &t1)
    {
        Point2d p10(p1.x()-p0.x(),p1.y()-p0.y());
        Point2d p21(p2.x()-p1.x(),p2.y()-p1.y());
        Point2d pn0(p0.x()+n0.x(),p0.y()+n0.y());
        Point2d pn1(p1.x()+n1.x(),p1.y()+n1.y());
        
        // Choose the form of the equation based on the size of this denominator
        double num, denom;
        if (std::abs(p10.x()) > std::abs(p10.y()))
        {
            double termA = p10.y()/p10.x();
            denom = p21.y() - p21.x() * termA;
            num = (pn1.x() - pn0.x())*termA + pn0.y()-pn1.y();
        } else {
            double termA = p10.x()/p10.y();
            denom = p21.y()*termA-p21.x();
            num = pn1.x() - pn0.x() + (pn0.y() - pn1.y())*termA;
        }
        if (denom == 0.0)
            return false;
        
        t1 = num/denom;
        iPt = (p2-p1) * t1 + p1 + n1;
        
        if (std::abs(p10.x()) > std::abs(p10.y()))
            t0 = (p21.x() * t1 + pn1.x() - pn0.x())/p10.x();
        else
            t0 = (p21.y() * t1 + pn1.y() - pn0.y())/p10.y();
                
        return true;
    }
    
    // Straight up 2D line intersection.  Z is ignred until the end.
    bool intersectLinesIn2D(const Point3d &p1,const Point3d &p2,const Point3d &p3,const Point3d &p4,Point3d *iPt)
    {
        float denom = (p1.x()-p2.x())*(p3.y()-p4.y()) - (p1.y() - p2.y())*(p3.x() - p4.x());
        if (denom == 0.0)
            return false;
        
        float termA = (p1.x()*p2.y() - p1.y()*p2.x());
        float termB = (p3.x() * p4.y() - p3.y() * p4.x());
        iPt->x() = ( termA * (p3.x() - p4.x()) - (p1.x() - p2.x()) * termB)/denom;
        iPt->y() = ( termA * (p3.y() - p4.y()) - (p1.y() - p2.y()) * termB)/denom;
        iPt->z() = 0.0;
        
        return true;
    }
    
    // Intersect lines using the origin,direction form. Just a 2D intersection
    bool intersectLinesDir(const Point3d &aOrg,const Point3d &aDir,const Point3d &bOrg,const Point3d &bDir,Point3d &iPt)
    {
        // Choose the form of the equation based on the size of this denominator
        double num, denom;
        if (std::abs(aDir.x()) > std::abs(aDir.y()))
        {
            double termA = aDir.y()/aDir.x();
            denom = bDir.y() - bDir.x() * termA;
            num = (bOrg.x() - aOrg.x())*termA + aOrg.y()-bOrg.y();
        } else {
            double termA = aDir.x()/aDir.y();
            denom = bDir.y()*termA-bDir.x();
            num = bOrg.x() - aOrg.x() + (aOrg.y() - bOrg.y())*termA;
        }
        if (denom == 0.0)
            return false;
        
        double t1 = num/denom;
        iPt = bDir * t1 + bOrg;
        
        return true;
    }
    
    // Add a rectangle to the drawable
    void addRect(BasicDrawable *drawable,Point3d *corners,TexCoord *texCoords,const Point3d &up,const RGBAColor &thisColor)
    {
        int startPt = drawable->getNumPoints();

        for (unsigned int vi=0;vi<4;vi++)
        {
            drawable->addPoint(corners[vi]);
            if (vecInfo.texID != EmptyIdentity)
                drawable->addTexCoord(0, texCoords[vi]);
            drawable->addNormal(up);
            drawable->addColor(thisColor);
        }
        
        drawable->addTriangle(BasicDrawable::Triangle(startPt+0,startPt+1,startPt+3));
        drawable->addTriangle(BasicDrawable::Triangle(startPt+1,startPt+2,startPt+3));
    }
    
    // Add a rectangle to the wide drawable
    void addWideRect(WideVectorDrawable *drawable,Point3d *corners,const Point3d &pa,const Point3d &pb,TexCoord *texCoords,const Point3d &up,const RGBAColor &thisColor)
    {
        int startPt = drawable->getNumPoints();
        
        for (unsigned int vi=0;vi<4;vi++)
        {
            drawable->addPoint(vi < 2 ? pa : pb);
            drawable->addDir(corners[vi]);
            if (vecInfo.texID != EmptyIdentity)
                drawable->addTexCoord(0, texCoords[vi]);
            drawable->addNormal(up);
            drawable->addColor(thisColor);
        }
        
        drawable->addTriangle(BasicDrawable::Triangle(startPt+0,startPt+1,startPt+3));
        drawable->addTriangle(BasicDrawable::Triangle(startPt+1,startPt+2,startPt+3));
    }
    
    // Add a triangle to the drawable
    void addTri(BasicDrawable *drawable,Point3d *corners,TexCoord *texCoords,const Point3d &up,const RGBAColor &thisColor)
    {
        int startPt = drawable->getNumPoints();
        
        for (unsigned int vi=0;vi<3;vi++)
        {
            drawable->addPoint(corners[vi]);
            if (vecInfo.texID != EmptyIdentity)
                drawable->addTexCoord(0, texCoords[vi]);
            drawable->addNormal(up);
            drawable->addColor(thisColor);
        }
        
        drawable->addTriangle(BasicDrawable::Triangle(startPt+0,startPt+1,startPt+2));
    }
    
    // Add a triangle to the wide drawable
    void addWideTri(WideVectorDrawable *drawable,Point3d *corners,const Point3d &org,TexCoord *texCoords,const Point3d &up,const RGBAColor &thisColor)
    {
        int startPt = drawable->getNumPoints();
        
        for (unsigned int vi=0;vi<3;vi++)
        {
            drawable->addPoint(org);
            drawable->addDir(corners[vi]);
            
            if (vecInfo.texID != EmptyIdentity)
                drawable->addTexCoord(0, texCoords[vi]);
            drawable->addNormal(up);
            drawable->addColor(thisColor);
        }
        
        drawable->addTriangle(BasicDrawable::Triangle(startPt+0,startPt+1,startPt+2));
    }
    
    // Build the polygons for a widened line segment
    void buildPolys(const Point3d *pa,const Point3d *pb,const Point3d *pc,const Point3d &up,BasicDrawable *drawable)
    {
        WideVectorDrawable *wideDrawable = dynamic_cast<WideVectorDrawable *>(drawable);
        
        double texLen = (*pb-*pa).norm();
        // Degenerate segment
        if (texLen == 0.0)
            return;
        texLen *= vecInfo.repeatSize;
        
        // Next segment is degenerate
        if (pc)
        {
            if ((*pc-*pb).norm() == 0.0)
                pc = NULL;
        }

        double calcScale = (vecInfo.coordType == WideVecCoordReal ? 1.0 : 1/EarthRadius);

        // We need the normal (with respect to the line), and its inverse
        // These are half, for half the width
        Point3d norm0 = (*pb-*pa).cross(up);
        norm0.normalize();
        norm0 /= 2.0;
        Point3d revNorm0 = norm0 * -1.0;
        
        Point3d norm1(0,0,0),revNorm1(0,0,0);
        if (pc)
        {
            norm1 = (*pc-*pb).cross(up);
            norm1.normalize();
            norm1 /= 2.0;
            revNorm1 = norm1 * -1.0;
        }
        
        if (vecInfo.coordType == WideVecCoordReal)
        {
            norm0 *= vecInfo.width;
            norm1 *= vecInfo.width;
            revNorm0 *= vecInfo.width;
            revNorm1 *= vecInfo.width;
        }

        Point3d paLocal = *pa-center;
        Point3d pbLocal = *pb-center;
        Point3d pbLocalAdj = pbLocal;

        // Look for valid starting points.  If they're not there, make some simple ones
        if (!edgePointsValid)
        {
            if (vecInfo.coordType == WideVecCoordReal)
            {
                e0 = paLocal + revNorm0;
                e1 = paLocal + norm0;
            } else {
                e0 = paLocal + revNorm0*calcScale;
                e1 = paLocal + norm0*calcScale;
            }
            centerAdj = paLocal;
        }
        
        RGBAColor thisColor = color;
        // Note: Debugging
        float scale = drand48() / 2 + 0.5;
        thisColor.r *= scale;
        thisColor.g *= scale;
        thisColor.b *= scale;
        
        // Calculate points for the expanded linear
        Point3d corners[4];
        TexCoord texCoords[4];
        
        Point3d rPt,lPt;
        Point3d pcLocal = (pc ? *pc-center: Point3d(0,0,0));
        Point3d dirA = (paLocal-pbLocal).normalized();
        Point3d dirB;
        
        // Figure out which way the bend goes and calculation intersection points
        double t0l,t1l,t0r,t1r;
        bool iPtsValid = false;
        if (pc)
        {
            // Compare the angle between the two segments.
            // We want to catch when the data folds back on itself.
            dirB = (pcLocal-pbLocal).normalized();
            double dot = dirA.dot(dirB);
            if (dot > -0.99999998476 && dot < 0.99999998476)
                if (intersectWideLines(paLocal,pbLocal,pcLocal,norm0*calcScale,norm1*calcScale,rPt,t0r,t1r) &&
                    intersectWideLines(paLocal,pbLocal,pcLocal,revNorm0*calcScale,revNorm1*calcScale,lPt,t0l,t1l))
                    iPtsValid = true;
        }
        
        // Points from the last round
        corners[0] = e0;
        corners[1] = e1;
        
        Point3d next_e0,next_e1,next_e0_dir,next_e1_dir;
        if (iPtsValid)
        {
            // Bending right
            if (t0l > 1.0)
            {
                if (vecInfo.coordType == WideVecCoordReal)
                {
                    corners[2] = rPt;
                    corners[3] = rPt + revNorm0 * 2;
                    next_e0 = rPt + revNorm1 * 2;
                    next_e1 = corners[2];
                } else {
                    corners[2] = rPt;
                    corners[3] = rPt + revNorm0 * calcScale * 2;

                    next_e0 = rPt + revNorm1 * calcScale * 2;
                    next_e1 = corners[2];
                }
            } else {
                // Bending left
                if (vecInfo.coordType == WideVecCoordReal)
                {
                    corners[2] = lPt + norm0 * 2;
                    corners[3] = lPt;
                    next_e0 = corners[3];
                    next_e1 = lPt + norm1 * 2;
                } else {
                    corners[2] = lPt + norm0 * calcScale * 2;
                    corners[3] = lPt;

                    next_e0 = lPt;
                    next_e1 = lPt + norm1 * calcScale * 2;
                }
            }
        } else {
            if (vecInfo.coordType == WideVecCoordReal)
            {
                corners[2] = pbLocal + norm0;
                corners[3] = pbLocal + revNorm0;
                next_e0 = corners[3];
                next_e1 = corners[2];
            } else {
                corners[2] = pbLocal + norm0 * calcScale;
                corners[3] = pbLocal + revNorm0 * calcScale;
                next_e0 = corners[3];
                next_e1 = corners[2];
            }
        }
        
        texCoords[0] = TexCoord(0.0,texOffset);
        texCoords[1] = TexCoord(1.0,texOffset+texLen);
        texCoords[2] = TexCoord(1.0,texOffset+texLen);
        texCoords[3] = TexCoord(0.0,texOffset);
        
        // Make an explicit join
        Point3d triVerts[3];
        TexCoord triTex[3];
        if (iPtsValid)
        {
            WideVectorLineJoinType joinType = vecInfo.joinType;
            
            // We may need to switch to a bevel join if miter is too extreme
            if (joinType == WideVecMiterJoin)
            {
                double len = 0.0;
                // Bending right
                if (t0l > 1.0)
                {
                    // Measure the distance from the left point to the middle
                    len = (lPt-pbLocal).norm()/calcScale;
                } else {
                    // Bending left
                    len = (rPt-pbLocal).norm()/calcScale;
                }
                
                if (vecInfo.coordType == WideVecCoordReal)
                {
                    if (2*len/vecInfo.width > vecInfo.miterLimit)
                        joinType = WideVecBevelJoin;
                } else {
                    if (2*len > vecInfo.miterLimit)
                        joinType = WideVecBevelJoin;
                }
            }
            
            switch (joinType)
            {
                case WideVecMiterJoin:
                {
                    // Bending right
                    if (t0l > 1.0)
                    {
                        // Build two triangles to join up to the middle
                        triTex[0] = TexCoord(0.0,texOffset+texLen);
                        triTex[1] = TexCoord(1.0,texOffset+texLen);
                        triTex[2] = TexCoord(0.0,texOffset+texLen);
                        if (vecInfo.coordType == WideVecCoordReal)
                        {
                            triVerts[0] = corners[3];
                            triVerts[1] = rPt;
                            triVerts[2] = lPt;
                            addTri(drawable,triVerts,triTex,up,thisColor);
                        } else {
                            triVerts[0] = (corners[3]-pbLocal)/calcScale;
                            triVerts[1] = (rPt-pbLocal)/calcScale;
                            triVerts[2] = (lPt-pbLocal)/calcScale;
                            addWideTri(wideDrawable,triVerts,pbLocal,triTex,up,thisColor);
                        }
                        triTex[0] = TexCoord(0.0,texOffset+texLen);
                        triTex[1] = TexCoord(1.0,texOffset+texLen);
                        triTex[2] = TexCoord(0.0,texOffset+texLen);
                        if (vecInfo.coordType == WideVecCoordReal)
                        {
                            triVerts[0] = lPt;
                            triVerts[1] = rPt;
                            triVerts[2] = next_e0;
                            addTri(drawable,triVerts,triTex,up,thisColor);
                        } else {
                            triVerts[0] = (lPt-pbLocal)/calcScale;
                            triVerts[1] = (rPt-pbLocal)/calcScale;
                            triVerts[2] = (next_e0-pbLocal)/calcScale;
                            addWideTri(wideDrawable,triVerts,pbLocal,triTex,up,thisColor);
                        }
                    } else {
                        // Bending left
                        triTex[0] = TexCoord(0.0,texOffset+texLen);
                        triTex[1] = TexCoord(1.0,texOffset+texLen);
                        triTex[2] = TexCoord(1.0,texOffset+texLen);
                        if (vecInfo.coordType == WideVecCoordReal)
                        {
                            triVerts[0] = lPt;
                            triVerts[1] = corners[2];
                            triVerts[2] = rPt;
                            addTri(drawable,triVerts,triTex,up,thisColor);
                        } else {
                            triVerts[0] = (lPt-pbLocal)/calcScale;
                            triVerts[1] = (corners[2]-pbLocal)/calcScale;
                            triVerts[2] = (rPt-pbLocal)/calcScale;
                            addWideTri(wideDrawable,triVerts,pbLocal,triTex,up,thisColor);
                        }
                        triTex[0] = TexCoord(0.0,texOffset+texLen);
                        triTex[1] = TexCoord(1.0,texOffset+texLen);
                        triTex[2] = TexCoord(1.0,texOffset+texLen);
                        if (vecInfo.coordType == WideVecCoordReal)
                        {
                            triVerts[0] = lPt;
                            triVerts[1] = rPt;
                            triVerts[2] = next_e1;
                            addTri(drawable,triVerts,triTex,up,thisColor);
                        } else {
                            triVerts[0] = (lPt-pbLocal)/calcScale;
                            triVerts[1] = (rPt-pbLocal)/calcScale;
                            triVerts[2] = (next_e1-pbLocal)/calcScale;
                            addWideTri(wideDrawable,triVerts,pbLocal,triTex,up,thisColor);
                        }
                    }
                }
                    break;
                case WideVecBevelJoin:
                {
                    // Bending right
                    if (t0l > 1.0)
                    {
                        // lPt1 is a point in the middle of the prospective bevel
                        Point3d lNorm = (lPt-pbLocal).normalized();
                        Point3d lPt1 = rPt + lNorm * vecInfo.miterLimit * calcScale * (vecInfo.coordType == WideVecCoordReal ? vecInfo.width : 1.0);
                        Point3d iNorm = up.cross(lNorm);
                        pbLocalAdj = (rPt+lPt1)/2.0;
                        
                        // Find the intersection points with the edges along the left side
                        Point3d li0,li1;
                        if (intersectLinesDir(lPt1,iNorm,corners[0],pbLocal-paLocal,li0) &&
                            intersectLinesDir(lPt1,iNorm,next_e0,pcLocal-pbLocal,li1))
                        {
                            // Form three triangles for this junction
                            triTex[0] = TexCoord(0.0,texOffset+texLen);
                            triTex[1] = TexCoord(1.0,texOffset+texLen);
                            triTex[2] = TexCoord(0.0,texOffset+texLen);
                            if (vecInfo.coordType == WideVecCoordReal)
                            {
                                triVerts[0] = corners[3];
                                triVerts[1] = rPt;
                                triVerts[2] = li0;
                                addTri(drawable,triVerts,triTex,up,thisColor);
                            } else {
                                triVerts[0] = (corners[3]-pbLocalAdj)/calcScale;
                                triVerts[1] = (rPt-pbLocalAdj)/calcScale;
                                triVerts[2] = (li0-pbLocalAdj)/calcScale;
                                addWideTri(wideDrawable,triVerts,pbLocalAdj,triTex,up,thisColor);
                            }
                            triTex[0] = TexCoord(0.0,texOffset+texLen);
                            triTex[1] = TexCoord(1.0,texOffset+texLen);
                            triTex[2] = TexCoord(0.0,texOffset+texLen);
                            if (vecInfo.coordType == WideVecCoordReal)
                            {
                                triVerts[0] = li0;
                                triVerts[1] = rPt;
                                triVerts[2] = li1;
                                addTri(drawable,triVerts,triTex,up,thisColor);
                            } else {
                                triVerts[0] = (li0-pbLocalAdj)/calcScale;
                                triVerts[1] = (rPt-pbLocalAdj)/calcScale;
                                triVerts[2] = (li1-pbLocalAdj)/calcScale;
                                addWideTri(wideDrawable,triVerts,pbLocalAdj,triTex,up,thisColor);
                            }
                            triTex[0] = TexCoord(0.0,texOffset+texLen);
                            triTex[1] = TexCoord(1.0,texOffset+texLen);
                            triTex[2] = TexCoord(0.0,texOffset+texLen);
                            if (vecInfo.coordType == WideVecCoordReal)
                            {
                                triVerts[0] = li1;
                                triVerts[1] = rPt;
                                triVerts[2] = next_e0;
                                addTri(drawable,triVerts,triTex,up,thisColor);
                            } else {
                                triVerts[0] = (li1-pbLocalAdj)/calcScale;
                                triVerts[1] = (rPt-pbLocalAdj)/calcScale;
                                triVerts[2] = (next_e0-pbLocalAdj)/calcScale;
                                addWideTri(wideDrawable,triVerts,pbLocalAdj,triTex,up,thisColor);
                            }
                        }
                    } else {
                        // Bending left
                        // rPt1 is a point in the middle of the prospective bevel
                        Point3d rNorm = (rPt-pbLocal).normalized();
                        Point3d rPt1 = lPt + rNorm * vecInfo.miterLimit * calcScale * (vecInfo.coordType == WideVecCoordReal ? vecInfo.width : 1.0);
                        Point3d iNorm = rNorm.cross(up);
                        pbLocalAdj = (lPt+rPt1)/2.0;
                        
                        // Find the intersection points with the edges along the right side
                        Point3d ri0,ri1;
                        if (intersectLinesDir(rPt1,iNorm,corners[1], pbLocal-paLocal, ri0) &&
                            intersectLinesDir(rPt1,iNorm,next_e1,pcLocal-pbLocal,ri1))
                        {
                            // Form three triangles for this junction
                            triTex[0] = TexCoord(0.0,texOffset+texLen);
                            triTex[1] = TexCoord(1.0,texOffset+texLen);
                            triTex[2] = TexCoord(1.0,texOffset+texLen);
                            if (vecInfo.coordType == WideVecCoordReal)
                            {
                                triVerts[0] = lPt;
                                triVerts[1] = corners[2];
                                triVerts[2] = ri0;
                                addTri(drawable,triVerts,triTex,up,thisColor);
                            } else {
                                triVerts[0] = (lPt-pbLocalAdj)/calcScale;
                                triVerts[1] = (corners[2]-pbLocalAdj)/calcScale;
                                triVerts[2] = (ri0-pbLocalAdj)/calcScale;
                                addWideTri(wideDrawable,triVerts,pbLocalAdj,triTex,up,thisColor);
                            }
                            triTex[0] = TexCoord(0.0,texOffset+texLen);
                            triTex[1] = TexCoord(1.0,texOffset+texLen);
                            triTex[2] = TexCoord(1.0,texOffset+texLen);
                            if (vecInfo.coordType == WideVecCoordReal)
                            {
                                triVerts[0] = lPt;
                                triVerts[1] = ri0;
                                triVerts[2] = ri1;
                                addTri(drawable,triVerts,triTex,up,thisColor);
                            } else {
                                triVerts[0] = (lPt-pbLocalAdj)/calcScale;
                                triVerts[1] = (ri0-pbLocalAdj)/calcScale;
                                triVerts[2] = (ri1-pbLocalAdj)/calcScale;
                                addWideTri(wideDrawable,triVerts,pbLocalAdj,triTex,up,thisColor);
                            }
                            triTex[0] = TexCoord(0.0,texOffset+texLen);
                            triTex[1] = TexCoord(1.0,texOffset+texLen);
                            triTex[2] = TexCoord(1.0,texOffset+texLen);
                            if (vecInfo.coordType == WideVecCoordReal)
                            {
                                triVerts[0] = lPt;
                                triVerts[1] = ri1;
                                triVerts[2] = next_e1;
                                addTri(drawable,triVerts,triTex,up,thisColor);
                            } else {
                                triVerts[0] = (lPt-pbLocalAdj)/calcScale;
                                triVerts[1] = (ri1-pbLocalAdj)/calcScale;
                                triVerts[2] = (next_e1-pbLocalAdj)/calcScale;
                                addWideTri(wideDrawable,triVerts,pbLocalAdj,triTex,up,thisColor);
                            }
                        }
                    }
                }
                    break;
                case WideVecRoundJoin:
                    break;
            }
        }
        
        // Add the segment rectangle
        if (vecInfo.coordType == WideVecCoordReal)
        {
            addRect(drawable,corners,texCoords,up,thisColor);
        } else {
            // Run the offsets for the corners.
            Point3d cornerVecs[4];
            for (unsigned int ii=0;ii<4;ii++)
                cornerVecs[ii] = (corners[ii]-((ii < 2) ? centerAdj : pbLocalAdj))/calcScale;

            addWideRect(wideDrawable,cornerVecs,paLocal,pbLocal,texCoords,up,thisColor);
        }
        
        e0 = next_e0;
        e1 = next_e1;
        centerAdj = pbLocalAdj;
        edgePointsValid = true;
        texOffset += texLen;
    }
    
    
    // Add a point to the widened linear we're building
    void addPoint(const Point3d &inPt,const Point3d &up,BasicDrawable *drawable)
    {
        pts.push_back(inPt);
        if (pts.size() >= 3)
        {
            const Point3d &pa = pts[pts.size()-3];
            const Point3d &pb = pts[pts.size()-2];
            const Point3d &pc = pts[pts.size()-1];
            buildPolys(&pa,&pb,&pc,up,drawable);
        }
        lastUp = up;
    }
    
    // Flush out any outstanding points
    void flush(BasicDrawable *drawable)
    {
        if (pts.size() >= 2)
        {
            const Point3d &pa = pts[pts.size()-2];
            const Point3d &pb = pts[pts.size()-1];
            buildPolys(&pa, &pb, NULL, lastUp, drawable);
        }
    }

    WhirlyKitWideVectorInfo *vecInfo;
    RGBAColor color;
    Point3d center;
    double angleCutoff;
    
    double texOffset;

    std::vector<Point3d> pts;
    Point3d lastUp;
    
    bool edgePointsValid;
    Point3d e0,e1,centerAdj;
};

// Used to build up drawables
class WideVectorDrawableBuilder
{
public:
    WideVectorDrawableBuilder(Scene *scene,WhirlyKitWideVectorInfo *vecInfo)
    : scene(scene), vecInfo(vecInfo), drawable(NULL), centerValid(false)
    {
        coordAdapter = scene->getCoordAdapter();
        coordSys = coordAdapter->getCoordSystem();
    }
    
    // Center to use for drawables we create
    void setCenter(const Point3d &newCenter)
    {
        centerValid = true;
        center = newCenter;
    }
    
    // Build or return a suitable drawable (depending on the mode)
    BasicDrawable *getDrawable(int ptCount,int triCount)
    {
        if (!drawable ||
            (drawable->getNumPoints()+ptCount > MaxDrawablePoints) ||
            (drawable->getNumTris()+triCount > MaxDrawableTriangles))
        {
            flush();
          
            if (vecInfo.coordType == WideVecCoordReal)
            {
                drawable = new BasicDrawable("WideVector");
            } else {
                WideVectorDrawable *wideDrawable = new WideVectorDrawable();
                drawable = wideDrawable;
                drawable->setProgram(vecInfo.shader);
                wideDrawable->setWidth(vecInfo.width);
            }
//            drawMbr.reset();
            drawable->setType(GL_TRIANGLES);
            drawable->setOnOff(vecInfo.enable);
            drawable->setColor([vecInfo.color asRGBAColor]);
            drawable->setDrawPriority(vecInfo.drawPriority);
            drawable->setVisibleRange(vecInfo.minVis,vecInfo.maxVis);
            if (vecInfo.texID != EmptyIdentity)
                drawable->setTexId(0, vecInfo.texID);
            if (centerValid)
            {
                Eigen::Affine3d trans(Eigen::Translation3d(center.x(),center.y(),center.z()));
                Matrix4d transMat = trans.matrix();
                drawable->setMatrix(&transMat);
            }
        }
        
        return drawable;
    }
    
    // Add the points for a linear
    void addLinear(VectorRing &pts)
    {
        // Note: Debugging
        RGBAColor color = [vecInfo.color asRGBAColor];
        color.r = random()%256;
        color.g = random()%256;
        color.b = random()%256;
        color.a = 255;
        WideVectorBuilder vecBuilder(vecInfo,center,color);
        
        // Work through the segments
        for (unsigned int ii=0;ii<pts.size();ii++)
        {
            // Get the points in display space
            Point2f geoA = pts[ii];
            Point3d localPa = coordSys->geographicToLocal3d(GeoCoord(geoA.x(),geoA.y()));
            Point3d pa = coordAdapter->localToDisplay(localPa);
            Point3d up = coordAdapter->normalForLocal(localPa);
            
            // Get a drawable ready
            int ptCount = 5;
            int triCount = 4;
            BasicDrawable *thisDrawable = getDrawable(ptCount,triCount);
            drawMbr.addPoint(geoA);
            
            vecBuilder.addPoint(pa,up,thisDrawable);
        }

        vecBuilder.flush(drawable);
    }

    // Flush out the drawables
    WideVectorSceneRep *flush(ChangeSet &changes)
    {
        flush();
        
        if (drawables.empty())
            return NULL;
        
        WideVectorSceneRep *sceneRep = new WideVectorSceneRep();
        for (unsigned int ii=0;ii<drawables.size();ii++)
        {
            Drawable *drawable = drawables[ii];
            sceneRep->drawIDs.insert(drawable->getId());
            changes.push_back(new AddDrawableReq(drawable));
        }
        
        drawables.clear();
        
        return sceneRep;
    }
    
protected:
    // Move an active drawable to the list
    void flush()
    {
        if (drawable)
        {
            drawable->setLocalMbr(drawMbr);
            drawables.push_back(drawable);
        }
        drawable = NULL;
    }

    bool centerValid;
    Point3d center;
    Mbr drawMbr;
    Scene *scene;
    CoordSystemDisplayAdapter *coordAdapter;
    CoordSystem *coordSys;
    WhirlyKitWideVectorInfo *vecInfo;
    BasicDrawable *drawable;
    std::vector<BasicDrawable *> drawables;
};
    
WideVectorSceneRep::WideVectorSceneRep()
{
}
    
WideVectorSceneRep::WideVectorSceneRep(SimpleIdentity inId)
    : Identifiable(inId)
{
}

WideVectorSceneRep::~WideVectorSceneRep()
{
}

void WideVectorSceneRep::enableContents(bool enable,ChangeSet &changes)
{
    for (SimpleIDSet::iterator it = drawIDs.begin();
         it != drawIDs.end(); ++it)
        changes.push_back(new OnOffChangeRequest(*it,enable));
}

void WideVectorSceneRep::clearContents(ChangeSet &changes)
{
    for (SimpleIDSet::iterator it = drawIDs.begin();
         it != drawIDs.end(); ++it)
        changes.push_back(new RemDrawableReq(*it));
}

WideVectorManager::WideVectorManager()
{
    pthread_mutex_init(&vecLock, NULL);
}

WideVectorManager::~WideVectorManager()
{
    pthread_mutex_destroy(&vecLock);
    for (WideVectorSceneRepSet::iterator it = sceneReps.begin();
         it != sceneReps.end(); ++it)
        delete *it;
    sceneReps.clear();
}
    
SimpleIdentity WideVectorManager::addVectors(ShapeSet *shapes,NSDictionary *desc,ChangeSet &changes)
{
    WhirlyKitWideVectorInfo *vecInfo = [[WhirlyKitWideVectorInfo alloc] init];
    [vecInfo parseDesc:desc];
    
    WideVectorDrawableBuilder builder(scene,vecInfo);
    
    // Calculate a center for this geometry
    GeoMbr geoMbr;
    for (ShapeSet::iterator it = shapes->begin(); it != shapes->end(); ++it)
    {
        GeoMbr thisMbr = (*it)->calcGeoMbr();
        geoMbr.expand(thisMbr);
    }
    // No data?
    if (!geoMbr.valid())
        return EmptyIdentity;
    GeoCoord centerGeo = geoMbr.mid();
    Point3d centerDisp = scene->getCoordAdapter()->localToDisplay(scene->getCoordAdapter()->getCoordSystem()->geographicToLocal3d(centerGeo));
    builder.setCenter(centerDisp);
    
    for (ShapeSet::iterator it = shapes->begin(); it != shapes->end(); ++it)
    {
        VectorLinearRef lin = boost::dynamic_pointer_cast<VectorLinear>(*it);
        if (lin)
        {
            builder.addLinear(lin->pts);
        }
    }
    
    WideVectorSceneRep *sceneRep = builder.flush(changes);
    SimpleIdentity vecID = sceneRep->getId();
    if (sceneRep)
    {
        vecID = sceneRep->getId();
        pthread_mutex_lock(&vecLock);
        sceneReps.insert(sceneRep);
        pthread_mutex_unlock(&vecLock);
    }
    
    return vecID;
}

void WideVectorManager::enableVectors(SimpleIDSet &vecIDs,bool enable,ChangeSet &changes)
{
    pthread_mutex_lock(&vecLock);
    
    for (SimpleIDSet::iterator vit = vecIDs.begin();vit != vecIDs.end();++vit)
    {
        WideVectorSceneRep dummyRep(*vit);
        WideVectorSceneRepSet::iterator it = sceneReps.find(&dummyRep);
        if (it != sceneReps.end())
        {
            WideVectorSceneRep *vecRep = *it;
            for (SimpleIDSet::iterator dit = vecRep->drawIDs.begin();
                 dit != vecRep->drawIDs.end(); ++dit)
                changes.push_back(new OnOffChangeRequest((*dit), enable));
        }
    }
    
    pthread_mutex_unlock(&vecLock);
}
    
void WideVectorManager::removeVectors(SimpleIDSet &vecIDs,ChangeSet &changes)
{
    pthread_mutex_lock(&vecLock);
    
    for (SimpleIDSet::iterator vit = vecIDs.begin();vit != vecIDs.end();++vit)
    {
        WideVectorSceneRep dummyRep(*vit);
        WideVectorSceneRepSet::iterator it = sceneReps.find(&dummyRep);
        NSTimeInterval curTime = CFAbsoluteTimeGetCurrent();
        if (it != sceneReps.end())
        {
            WideVectorSceneRep *sceneRep = *it;
            
            if (sceneRep->fade > 0.0)
            {
                for (SimpleIDSet::iterator it = sceneRep->drawIDs.begin();
                     it != sceneRep->drawIDs.end(); ++it)
                    changes.push_back(new FadeChangeRequest(*it, curTime, curTime+sceneRep->fade));
                
                // Spawn off the deletion for later
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, sceneRep->fade * NSEC_PER_SEC),
                               scene->getDispatchQueue(),
                               ^{
                                   SimpleIDSet theIDs;
                                   theIDs.insert(sceneRep->getId());
                                   ChangeSet delChanges;
                                   removeVectors(theIDs, delChanges);
                                   scene->addChangeRequests(delChanges);
                               }
                               );
                
                sceneRep->fade = 0.0;
            } else {
                (*it)->clearContents(changes);
                sceneReps.erase(it);
                delete sceneRep;
            }
        }
    }
    
    pthread_mutex_unlock(&vecLock);
}

}
